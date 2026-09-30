/* oxlint-disable jsx-a11y/prefer-tag-over-role -- A space row hosts its own "…" button, so the activatable surface cannot itself be a button element. */
/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
/* oxlint-disable jsx-a11y/no-static-element-interactions, jsx-a11y/no-noninteractive-element-interactions -- The rail's empty area only takes a right click, to offer the folder actions; every row inside stays a real button. */
import { useCommaMessages } from "@comma/i18n/react";
import {
  CloudOffIcon,
  cx,
  Folder1Icon,
  FolderAddRightIcon,
  EditBigIcon,
  FolderOpenIcon,
  FolderUploadIcon,
  getMenuPointerOffsets,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  menuItemClasses,
  menuSurfaceClasses,
  MoreHorizontalIcon,
  ScrollArea,
  Toggle,
  Tooltip,
  TrashCanIcon,
  type MenuPointerOffsets,
} from "@comma/ui";
import { useRef, type RefObject } from "react";
import { commaDriveSpaceRailWidth } from "../shellGeometry";
import { useDriveContextMenu } from "./DriveItemMenu";
import type { DriveSpace } from "./driveStore";

export type DriveRailMenuAction = "new-folder" | "upload-folder";
export type DriveSpaceMenuAction = "delete" | "rename";

/** The rail's own menu, from a right click on its empty area: make or bring a folder. */
function DriveRailMenuPopover({
  isOpen,
  newFolderLabel,
  onAction,
  onOpenChange,
  pointerOffsets,
  triggerRef,
  uploadFolderLabel,
}: {
  isOpen: boolean;
  newFolderLabel: string;
  onAction: (action: DriveRailMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  triggerRef: RefObject<HTMLElement | null>;
  uploadFolderLabel: string;
}) {
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
      placement={pointerOffsets ? "right top" : "bottom start"}
      triggerRef={triggerRef}
    >
      <Menu
        autoFocus="first"
        onAction={(key) => onAction(key as DriveRailMenuAction)}
        onClose={() => onOpenChange(false)}
      >
        <MenuItem icon={<FolderAddRightIcon />} id="new-folder">
          {newFolderLabel}
        </MenuItem>
        <MenuItem icon={<FolderUploadIcon />} id="upload-folder">
          {uploadFolderLabel}
        </MenuItem>
      </Menu>
    </MenuPopover>
  );
}

/**
 * A space row's menu: its own sync switch first (the one setting that is
 * about this device), then the folder actions, with Delete alone at the
 * bottom in the destructive tone.
 */
function DriveSpaceMenuPopover({
  isOpen,
  onAction,
  onOpenChange,
  onSyncedChange,
  pointerOffsets,
  space,
  triggerRef,
}: {
  isOpen: boolean;
  onAction: (action: DriveSpaceMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  onSyncedChange: (synced: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  space: DriveSpace;
  triggerRef: RefObject<HTMLElement | null>;
}) {
  const messages = useCommaMessages();
  if (!isOpen) return null;
  return (
    <MenuPopover
      className="w-64 motion-reduce:animate-none"
      crossOffset={pointerOffsets?.crossOffset ?? 0}
      dismissControlledNonModalOnInteractOutside
      isNonModal
      isOpen={isOpen}
      offset={pointerOffsets?.offset ?? 0}
      onOpenChange={onOpenChange}
      placement={pointerOffsets ? "right top" : "bottom end"}
      triggerRef={triggerRef}
    >
      {/* The popover paints no surface of its own — a plain Menu brings one —
          so the switch row and the embedded menu share one card here. */}
      <div className={cx(menuSurfaceClasses, "flex w-full flex-col py-sm")}>
        {/* Not a menu item — flipping the switch must not close the menu —
            but it sits in the same column as one: the menu's own row metrics
            (gutter, padding, icon slot, icon-to-label gap) so the glyph and the label
            line up with Rename and Delete below. */}
        <div
          className={menuItemClasses.gutter}
          data-testid={`drive-space-sync-row-${space.id}`}
        >
          <div
            className={cx(
              menuItemClasses.content,
              menuItemClasses.row,
              "justify-between gap-md"
            )}
          >
            <span className={menuItemClasses.leading}>
              <span className={menuItemClasses.icon}>
                <CloudOffIcon />
              </span>
              <span className="truncate">{messages.drive_space_menu_sync()}</span>
            </span>
            <Toggle
              aria-label={messages.drive_space_menu_sync()}
              checked={space.synced ?? false}
              onChange={(event) => onSyncedChange(event.target.checked)}
              size="sm"
            />
          </div>
        </div>
        {/* The install's own folder is what this device publishes from: it
            has no other name to take, and it is not something to delete. */}
        {!space.protected && (
          <>
            <MenuSeparator />
            <Menu
              autoFocus="first"
              onAction={(key) => onAction(key as DriveSpaceMenuAction)}
              onClose={() => onOpenChange(false)}
              variant="embedded"
            >
              <MenuItem icon={<EditBigIcon />} id="rename">
                {messages.drive_space_menu_rename()}
              </MenuItem>
              <MenuSeparator />
              <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
                {messages.drive_space_menu_delete()}
              </MenuItem>
            </Menu>
          </>
        )}
      </div>
    </MenuPopover>
  );
}

function DriveSpaceRow({
  active,
  onMenuAction,
  onSelect,
  onSyncedChange,
  space,
}: {
  active: boolean;
  onMenuAction: (action: DriveSpaceMenuAction, space: DriveSpace) => void;
  onSelect: (spaceId: string) => void;
  onSyncedChange: (space: DriveSpace, synced: boolean) => void;
  space: DriveSpace;
}) {
  const messages = useCommaMessages();
  const rowRef = useRef<HTMLDivElement | null>(null);
  const menu = useDriveContextMenu();

  return (
    <>
      <div
        className={cx(
          // Instant hover, like the file rows beside it.
          "group/drive-space relative flex w-full min-w-0 cursor-default items-center gap-md rounded-lg px-md py-sm text-left outline-none",
          "focus-visible:shadow-focus-gray",
          active || menu.isOpen
            ? "bg-sidebar-bg-item text-sidebar-text-highlight"
            : "text-sidebar-text-secondary hover:bg-sidebar-bg-item"
        )}
        data-selected={active ? "true" : undefined}
        data-synced={space.synced ? "true" : "false"}
        data-testid={`drive-space-${space.id}`}
        onClick={() => onSelect(space.id)}
        onContextMenu={(event) => {
          if (!rowRef.current) return;
          event.preventDefault();
          event.stopPropagation();
          menu.open(
            getMenuPointerOffsets(rowRef.current, event.clientX, event.clientY)
          );
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            onSelect(space.id);
          }
        }}
        ref={rowRef}
        role="button"
        tabIndex={0}
      >
        {/* The selected space reads as the open folder. */}
        {active ? (
          <FolderOpenIcon aria-hidden className="size-5 shrink-0 text-quaternary" />
        ) : (
          <Folder1Icon aria-hidden className="size-5 shrink-0 text-quaternary" />
        )}
        <span className="min-w-0 truncate text-sm">{space.name}</span>
        {space.synced ? null : (
          <Tooltip content={messages.drive_space_not_synced()} placement="top">
            <span
              aria-label={messages.drive_space_not_synced()}
              className="flex shrink-0 items-center text-quaternary"
              data-testid={`drive-space-unsynced-${space.id}`}
              role="img"
            >
              <CloudOffIcon className="size-4" />
            </span>
          </Tooltip>
        )}
        <span className="min-w-0 flex-1" />
        <button
          aria-label={messages.drive_space_more_actions({ spaceName: space.name })}
          className={cx(
            "inline-flex size-5 shrink-0 items-center justify-center rounded-sm border-0 bg-transparent p-0 text-quaternary outline-none",
            "hover:text-secondary focus-visible:opacity-100 focus-visible:shadow-focus-gray",
            menu.isOpen
              ? "opacity-100"
              : "opacity-0 group-hover/drive-space:opacity-100"
          )}
          onClick={(event) => {
            event.stopPropagation();
            menu.open(null);
          }}
          type="button"
        >
          <MoreHorizontalIcon aria-hidden className="size-5" />
        </button>
      </div>
      <DriveSpaceMenuPopover
        isOpen={menu.isOpen}
        onAction={(action) => onMenuAction(action, space)}
        onOpenChange={menu.onOpenChange}
        onSyncedChange={(synced) => onSyncedChange(space, synced)}
        pointerOffsets={menu.pointerOffsets}
        space={space}
        triggerRef={rowRef}
      />
    </>
  );
}

export function DriveSpaceRail({
  onMenuAction,
  onRailAction,
  onSelect,
  onSyncedChange,
  selectedSpaceId,
  spaces,
}: {
  onMenuAction: (action: DriveSpaceMenuAction, space: DriveSpace) => void;
  onRailAction: (action: DriveRailMenuAction) => void;
  onSelect: (spaceId: string) => void;
  onSyncedChange: (space: DriveSpace, synced: boolean) => void;
  selectedSpaceId: string;
  spaces: readonly DriveSpace[];
}) {
  const messages = useCommaMessages();
  const railRef = useRef<HTMLElement | null>(null);
  const railMenu = useDriveContextMenu();
  return (
    <nav
      aria-label={messages.drive_spaces()}
      className="flex shrink-0 flex-col border-r-[0.5px] border-primary"
      data-testid="drive-space-rail"
      onContextMenu={(event) => {
        // Rows stop propagation of their own right click; anything that
        // reaches here is the rail's blank space.
        if (!railRef.current) return;
        event.preventDefault();
        railMenu.open(
          getMenuPointerOffsets(railRef.current, event.clientX, event.clientY)
        );
      }}
      ref={railRef}
      style={{ flexBasis: commaDriveSpaceRailWidth, width: commaDriveSpaceRailWidth }}
    >
      <ScrollArea className="min-h-0 flex-1">
        <div className="flex flex-col gap-xxs px-md py-lg">
          {spaces.map((space) => (
            <DriveSpaceRow
              active={space.id === selectedSpaceId}
              key={space.id}
              onMenuAction={onMenuAction}
              onSelect={onSelect}
              onSyncedChange={onSyncedChange}
              space={space}
            />
          ))}
        </div>
      </ScrollArea>
      <DriveRailMenuPopover
        isOpen={railMenu.isOpen}
        newFolderLabel={messages.drive_rail_menu_new_folder()}
        onAction={onRailAction}
        onOpenChange={railMenu.onOpenChange}
        pointerOffsets={railMenu.pointerOffsets}
        triggerRef={railRef}
        uploadFolderLabel={messages.drive_rail_menu_upload_folder()}
      />
    </nav>
  );
}
