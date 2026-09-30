import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  ArrowTopBottomIcon,
  BranchIcon,
  ChevronDownSmallIcon,
  CloudUploadIcon,
  FolderUploadIcon,
  ChevronRightSmallIcon,
  cx,
  DevicesIcon,
  Filter2Icon,
  FilterOptionsPanel,
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  motionDuration,
  spacing,
  SubmenuTrigger,
  taskToolbarIconButtonClassName,
} from "@comma/ui";
import { useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { drivePrimaryButton, driveSecondaryButton } from "./driveButtonStyles";
import { DriveSyncPanel } from "./DriveSyncPanel";
import type { DriveDevice, DriveVersionPolicy } from "./driveStore";

/** Toolbar scale: 12px/18px labels. */
const toolbarSecondaryButton = `${driveSecondaryButton} text-xs`;
const toolbarPrimaryButton = `${drivePrimaryButton} text-xs`;

/**
 * One single-select filter panel — the Inbox/Tasks "pick from a list" chrome:
 * a search field over a list where exactly one row is checked.
 */
function DriveFilterPanel({
  items,
  label,
  onSelect,
  selectedId,
  testId,
}: {
  items: readonly { id: string; label: string }[];
  label: string;
  onSelect: (id: string) => void;
  selectedId: string;
  testId: string;
}) {
  const locale = useCommaLocale();
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const visible = items.filter((item) =>
    item.label.toLocaleLowerCase(locale).includes(normalizedQuery)
  );
  return (
    <div data-testid={testId}>
      <FilterOptionsPanel
        empty={visible.length === 0}
        label={label}
        onQueryChange={setQuery}
        query={query}
      >
        <Menu
          aria-label={label}
          className="flex min-w-0 flex-col gap-xxs px-sm py-sm"
          disallowEmptySelection
          onSelectionChange={(keys) => {
            if (keys === "all") return;
            const [key] = Array.from(keys);
            if (key !== undefined) onSelect(String(key));
          }}
          selectedKeys={[selectedId]}
          selectionMode="single"
          variant="embedded"
        >
          {visible.map((item) => (
            <MenuItem
              activeClassName="bg-secondary-hover"
              contentClassName="h-8"
              gutter="none"
              id={item.id}
              key={item.id}
              selectionIndicator="check"
              textValue={item.label}
            >
              <span className="text-primary">{item.label}</span>
            </MenuItem>
          ))}
        </Menu>
      </FilterOptionsPanel>
    </div>
  );
}

/**
 * The listing's two read policies behind one filter button, the way the
 * Inbox rail filters: a first level naming what can be filtered (device,
 * version), each opening its own single-select panel. The button reads as
 * filtered whenever either policy is off its default, so a pinned origin or a
 * strict read is never silently in force.
 */
function DriveFilterMenu({
  devices,
  onSelectDevice,
  onSelectVersionPolicy,
  originDeviceId,
  versionPolicy,
}: {
  devices: readonly DriveDevice[];
  onSelectDevice: (deviceId: string) => void;
  onSelectVersionPolicy: (policy: DriveVersionPolicy) => void;
  originDeviceId: string;
  versionPolicy: DriveVersionPolicy;
}) {
  const messages = useCommaMessages();
  const currentDeviceId = devices.find((device) => device.current)?.id;
  const isFiltered = originDeviceId !== currentDeviceId || versionPolicy !== "newest";
  const originDevice = devices.find((device) => device.id === originDeviceId);
  const originLabel = originDevice
    ? originDevice.current
      ? messages.drive_device_this_mac()
      : originDevice.label
    : messages.drive_device_filter_label();
  const policyLabel =
    versionPolicy === "newest"
      ? messages.drive_version_policy_newest()
      : messages.drive_version_policy_strict();

  return (
    <MenuTrigger>
      <AriaButton
        aria-label={messages.drive_filters()}
        className={cx(
          taskToolbarIconButtonClassName,
          isFiltered && "bg-tertiary text-primary"
        )}
        data-filtered={isFiltered ? "true" : "false"}
        data-testid="drive-filter-trigger"
      >
        <Filter2Icon />
      </AriaButton>
      <MenuPopover
        closeSubmenusOnPointerLeave
        offset={spacing.xs}
        placement="bottom start"
      >
        <Menu
          aria-label={messages.drive_filters()}
          className="w-56 bg-popup-secondary px-sm py-sm shadow-2xl"
        >
          <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
            <MenuItem
              activeClassName="bg-secondary-hover text-sidebar-text-highlight"
              appearance="sidebar"
              className="pointer-events-auto"
              contentClassName="h-8"
              gutter="none"
              icon={<DevicesIcon />}
              id="device"
              shortcut={
                <span className="flex items-center gap-xs">
                  <span className="text-xs text-quaternary">{originLabel}</span>
                  <ChevronRightSmallIcon className="size-4" />
                </span>
              }
              textValue={messages.drive_device_filter_label()}
            >
              {messages.drive_device_filter_label()}
            </MenuItem>
            <MenuPopover offset={0} placement="right top">
              <DriveFilterPanel
                items={devices.map((device) => ({
                  id: device.id,
                  label: device.current
                    ? messages.drive_device_this_mac()
                    : device.label,
                }))}
                label={messages.drive_device_filter_label()}
                onSelect={onSelectDevice}
                selectedId={originDeviceId}
                testId="drive-device-select"
              />
            </MenuPopover>
          </SubmenuTrigger>
          <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
            <MenuItem
              activeClassName="bg-secondary-hover text-sidebar-text-highlight"
              appearance="sidebar"
              className="pointer-events-auto"
              contentClassName="h-8"
              gutter="none"
              icon={<BranchIcon />}
              id="version"
              shortcut={
                <span className="flex items-center gap-xs">
                  <span className="text-xs text-quaternary">{policyLabel}</span>
                  <ChevronRightSmallIcon className="size-4" />
                </span>
              }
              textValue={messages.drive_version_policy_label()}
            >
              {messages.drive_version_policy_label()}
            </MenuItem>
            <MenuPopover offset={0} placement="right top">
              <DriveFilterPanel
                items={[
                  { id: "newest", label: messages.drive_version_policy_newest() },
                  { id: "strict", label: messages.drive_version_policy_strict() },
                ]}
                label={messages.drive_version_policy_label()}
                onSelect={(id) => onSelectVersionPolicy(id as DriveVersionPolicy)}
                selectedId={versionPolicy}
                testId="drive-version-policy-select"
              />
            </MenuPopover>
          </SubmenuTrigger>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

export function DriveToolbar({
  className,
  devices,
  localSyncEnabled,
  localSyncRoot,
  onLocalSyncEnabledChange,
  onOpenLocalRoot,
  onOpenSyncHistory,
  onSelectDevice,
  onSelectVersionPolicy,
  onToggleTransfers,
  onUploadFiles,
  onUploadFolder,
  originDeviceId,
  versionPolicy,
  writable,
}: {
  className?: string;
  devices: readonly DriveDevice[];
  localSyncEnabled: boolean;
  localSyncRoot: string;
  onLocalSyncEnabledChange: (enabled: boolean) => void;
  onOpenLocalRoot: () => void;
  onOpenSyncHistory: () => void;
  onSelectDevice: (deviceId: string) => void;
  onSelectVersionPolicy: (policy: DriveVersionPolicy) => void;
  onToggleTransfers: () => void;
  onUploadFiles: () => void;
  onUploadFolder: () => void;
  originDeviceId: string;
  versionPolicy: DriveVersionPolicy;
  writable: boolean;
}) {
  const messages = useCommaMessages();

  return (
    <div className={cx("flex min-w-0 items-center justify-between gap-md", className)}>
      <div className="flex min-w-0 items-center gap-md">
        <DriveFilterMenu
          devices={devices}
          onSelectDevice={onSelectDevice}
          onSelectVersionPolicy={onSelectVersionPolicy}
          originDeviceId={originDeviceId}
          versionPolicy={versionPolicy}
        />
        <DriveSyncPanel
          enabled={localSyncEnabled}
          localRoot={localSyncRoot}
          onEnabledChange={onLocalSyncEnabledChange}
          onOpenHistory={onOpenSyncHistory}
          onOpenLocally={onOpenLocalRoot}
        />
      </div>
      <div className="flex shrink-0 items-center gap-md">
        <button
          className={cx(toolbarSecondaryButton, "pl-md pr-lg")}
          data-testid="drive-transfer-toggle"
          onClick={onToggleTransfers}
          type="button"
        >
          <ArrowTopBottomIcon aria-hidden className="size-4 text-quaternary" />
          <span className="px-xxs whitespace-nowrap">
            {messages.drive_toolbar_transfer()}
          </span>
        </button>
        {/* Add files is a small menu: a folder brings its whole tree along,
            files land in the folder the list is showing. */}
        <MenuTrigger>
          <AriaButton
            className={toolbarPrimaryButton}
            data-testid="drive-add-files"
            isDisabled={!writable}
          >
            <span className="px-xxs whitespace-nowrap">
              {messages.drive_toolbar_add_files()}
            </span>
            <ChevronDownSmallIcon
              aria-hidden
              className="size-4 text-button-primary-fg"
            />
          </AriaButton>
          <MenuPopover
            className="min-w-52 motion-reduce:animate-none"
            placement="bottom end"
          >
            <Menu
              aria-label={messages.drive_toolbar_add_files()}
              onAction={(key) => {
                if (key === "upload-folder") onUploadFolder();
                else onUploadFiles();
              }}
            >
              <MenuItem icon={<FolderUploadIcon />} id="upload-folder">
                {messages.drive_add_menu_upload_folder()}
              </MenuItem>
              <MenuItem icon={<CloudUploadIcon />} id="upload-files">
                {messages.drive_add_menu_upload_files()}
              </MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      </div>
    </div>
  );
}
