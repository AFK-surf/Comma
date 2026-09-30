/* oxlint-disable jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions -- The keep cell only fences clicks so pressing the button never doubles as the row's own selection gesture; the button inside it carries the keyboard behaviour. */
import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { cx } from "@comma/ui";
import { useState } from "react";
import { Button as AriaButton, Radio, RadioGroup } from "react-aria-components";
import { driveSecondaryButton } from "./driveButtonStyles";
import {
  formatDriveFileSize,
  type DriveDevice,
  type DriveFile,
  type DriveFileVersion,
} from "./driveStore";

/** A ring that fills in when picked; the state the row is really about. */
const versionMark = [
  "flex size-4 shrink-0 items-center justify-center rounded-full border",
  "transition-colors duration-100",
].join(" ");

function DriveVersionRow({
  current,
  deviceLabel,
  isSelected,
  onKeep,
  own,
  version,
  writable,
}: {
  current: boolean;
  deviceLabel: string;
  isSelected: boolean;
  onKeep: () => void;
  /** This device's own copy: nothing to keep here, the other devices decide about theirs. */
  own: boolean;
  version: DriveFileVersion;
  writable: boolean;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  return (
    <span className="flex min-w-0 flex-1 items-center gap-md">
      <span
        className={cx(
          versionMark,
          isSelected ? "border-brand-solid bg-brand-solid" : "border-primary bg-primary"
        )}
      >
        {isSelected ? <span className="size-1.5 rounded-full bg-white" /> : null}
      </span>
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="flex min-w-0 items-center gap-md">
          <span className="min-w-0 truncate text-sm text-primary">{deviceLabel}</span>
          {/* Which copy the file is showing right now: the one thing a reader
              needs before they can judge the others. */}
          {current ? (
            <span className="shrink-0 rounded-full bg-quaternary px-md py-xxs text-xs text-quaternary">
              {messages.drive_versions_current()}
            </span>
          ) : null}
        </span>
        <span className="min-w-0 truncate text-xs text-quaternary tabular-nums">
          {version.deleted
            ? messages.drive_versions_deleted()
            : messages.drive_versions_detail({
                size: formatDriveFileSize(version.sizeBytes),
                when: formatDate(version.modifiedAt, locale, {
                  dateStyle: "medium",
                  hourCycle: "h23",
                  timeStyle: "short",
                }),
              })}
        </span>
      </span>
      {/* The commit sits on the row it commits to, so "this version" needs no
          antecedent. It is carved out of the row's own press, the way the file
          list carves out its checkbox cell. */}
      {isSelected && own ? (
        <span className="shrink-0 text-xs text-quaternary">
          {messages.drive_versions_yours()}
        </span>
      ) : isSelected && writable ? (
        <span
          className="shrink-0"
          onClick={(event) => event.stopPropagation()}
          onPointerDown={(event) => event.stopPropagation()}
        >
          {/* The toolbar's pill, at the toolbar's scale: one secondary button
              across Drive's surfaces. */}
          <AriaButton
            className={cx(driveSecondaryButton, "text-xs")}
            data-testid="drive-versions-keep"
            onPress={onKeep}
          >
            <span className="px-xxs whitespace-nowrap">
              {messages.drive_versions_keep()}
            </span>
          </AriaButton>
        </span>
      ) : null}
    </span>
  );
}

/**
 * What "5 versions" actually means, said plainly: the same file was edited in
 * more than one place, so the cluster is holding every copy. The panel names
 * where each copy came from, marks the one on screen, and settles the path on
 * whichever the reader picks — the choice Synchronicity's `--select` makes by
 * policy, made by hand and in words a first-time reader can act on.
 */
export function DriveVersionsPanel({
  devices,
  file,
  onKeep,
  ownDeviceId,
  writable,
}: {
  devices: readonly DriveDevice[];
  file: DriveFile;
  onKeep: (version: DriveFileVersion) => void;
  /** The device this app runs on; its own copy of a path is not something it can keep from here. */
  ownDeviceId?: string | undefined;
  writable: boolean;
}) {
  const messages = useCommaMessages();
  const versions = file.versions ?? [];
  const head = versions[0];
  // The shown copy is the default pick, and it resets when the panel moves to
  // another file rather than carrying the previous file's choice over.
  const [selectedId, setSelectedId] = useState(head?.id ?? "");
  const [lastHeadId, setLastHeadId] = useState(head?.id ?? "");
  if (head && head.id !== lastHeadId) {
    setLastHeadId(head.id);
    setSelectedId(head.id);
  }
  if (versions.length < 2) return null;

  const deviceLabel = (deviceId: string) =>
    devices.find((device) => device.id === deviceId)?.label ?? deviceId;

  return (
    <section
      className="flex shrink-0 flex-col gap-lg border-t-[0.5px] border-primary px-xl py-lg"
      data-testid="drive-versions-panel"
    >
      <div className="flex min-w-0 flex-col">
        <h3 className="m-0 text-sm font-semibold text-primary">
          {messages.drive_versions_title({ count: String(versions.length) })}
        </h3>
        <p className="m-0 text-xs text-pretty text-quaternary">
          {messages.drive_versions_description()}
        </p>
      </div>

      <RadioGroup
        aria-label={messages.drive_versions_choose({ fileName: file.name })}
        className="-mx-md flex flex-col"
        onChange={setSelectedId}
        value={selectedId}
      >
        {versions.map((version) => (
          <Radio
            className={cx(
              "flex w-full cursor-default items-center rounded-md px-md py-sm outline-none",
              "transition-colors duration-100 hover:bg-quaternary",
              "focus-visible:shadow-focus-gray",
              "data-[selected]:bg-quaternary"
            )}
            data-testid={`drive-version-${version.id}`}
            key={version.id}
            value={version.id}
          >
            {({ isSelected }) => (
              <DriveVersionRow
                current={version.id === head?.id}
                deviceLabel={deviceLabel(version.deviceId)}
                isSelected={isSelected}
                onKeep={() => onKeep(version)}
                own={version.deviceId === ownDeviceId}
                version={version}
                writable={writable}
              />
            )}
          </Radio>
        ))}
      </RadioGroup>
    </section>
  );
}
