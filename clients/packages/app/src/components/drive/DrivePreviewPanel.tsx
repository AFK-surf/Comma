import type { AttachmentUploadInput } from "../chat/model/conversationChannel";
import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  CheckIcon,
  CopyIcon,
  toast,
  Tooltip,
  type ChatPanelMediaDownloadAction,
} from "@comma/ui";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ShellIconButtonControl } from "../ShellIconButton";
import { DriveVersionsPanel } from "./DriveVersionsPanel";
import {
  driveFileKind,
  formatDriveFileSize,
  getDriveStore,
  useDriveSnapshot,
  type DriveFileVersion,
} from "./driveStore";
import {
  ensureDriveFileBlob,
  ensureDriveFileVersions,
  getDriveBackend,
  refreshDrive,
} from "./driveBackend";
import { downloadDriveFile } from "./driveTransfers";
import { FilePreviewPanel } from "../file-preview/FilePreviewPanel";
import { createResolvedFileOpenInAction } from "../../runtime-files/fileOpenActions";

import { copyImageBlob } from "../../runtime-files/imageClipboard";

function DrivePreviewMetaRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex w-full items-baseline gap-3xl">
      <dt className="m-0 w-[60px] shrink-0 text-sm font-medium text-quaternary">
        {label}
      </dt>
      <dd className="m-0 min-w-0 flex-1 truncate text-right text-sm text-primary">
        {value}
      </dd>
    </div>
  );
}

/**
 * The Drive file preview, rendered as one panel of the shell's shared right
 * sidebar. It resolves its own file from the Drive store so the sidebar only
 * has to carry the file id in its tab.
 */
export function DrivePreviewPanel({
  fileId,
  panelId,
  onOpenBrowser,
  onAttachFiles,
}: {
  fileId: string;
  panelId: string;
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const store = getDriveStore();
  const snapshot = useDriveSnapshot(store);
  const file = snapshot.files.find((entry) => entry.id === fileId);
  const bridge = getNativeBridge();
  const backend = getDriveBackend();
  const hasBlob = file?.blob !== undefined;
  const sourceKey = file
    ? JSON.stringify([file.id, file.deviceId, file.contentsHash])
    : fileId;
  const [failure, setFailure] = useState<{ sourceKey: string; message: string }>();
  const wantsVersions =
    file !== undefined && file.versions === undefined && (file.versionCount ?? 1) > 1;
  // The node holds the bytes and the copies; the panel asks for them on open
  // and again should a reload of the listing drop them.
  useEffect(() => {
    if (!backend) return;
    const current = store.getSnapshot().files.find((entry) => entry.id === fileId);
    if (!current) return;
    let active = true;
    if (current.blob === undefined) {
      void ensureDriveFileBlob(store, backend, current).catch(() => {
        if (active) setFailure({ sourceKey, message: messages.file_preview_failed() });
      });
    }
    if (current.versions === undefined && (current.versionCount ?? 1) > 1) {
      void ensureDriveFileVersions(store, backend, current).catch(() => {});
    }
    return () => {
      active = false;
    };
  }, [backend, fileId, sourceKey, hasBlob, wantsVersions, store, messages]);
  const [copied, setCopied] = useState(false);
  const copiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
    },
    []
  );

  // Drive transfers keep their existing streaming/download owner and transfer rows.
  const download = useMemo<ChatPanelMediaDownloadAction | undefined>(
    () =>
      file
        ? {
            fileName: file.name,
            capability: {
              execute: async () =>
                (await downloadDriveFile(store, file, {
                  ...(backend ? { backend } : {}),
                  bridge,
                  locale,
                }))
                  ? { status: "success" }
                  : { status: "error", code: "unknown", retryable: true },
            },
          }
        : undefined,
    [backend, bridge, file, locale, store]
  );
  const blob = file?.blob;
  const fileName = file?.name;
  const selection = useMemo(
    () => ({ blob, fileId, fileName, signal: AbortSignal.abort() }),
    [blob, fileId, fileName]
  );
  useEffect(() => {
    // Effect setup owns the live signal, including StrictMode's setup replay.
    // tla/file-actions/FileAction.tla: Replace/Close retire this selection.
    const controller = new AbortController();
    selection.signal = controller.signal;
    return () => controller.abort();
  }, [selection]);
  const openIn = useMemo(
    () =>
      blob && fileName
        ? createResolvedFileOpenInAction({
            // A mutable Drive id is not a byte identity. A new Blob has a new receipt owner.
            owner: blob,
            sourceKey: JSON.stringify([fileId, fileName]),
            fileName,
            resolveBytes: async () => blob,
            bridge,
            locale,
            beginAttempt: () => {
              const signal = selection.signal;
              return { signal, isCurrent: () => !signal.aborted, release: () => {} };
            },
          })
        : undefined,
    [blob, fileId, fileName, bridge, locale, selection]
  );

  const keepVersion = useCallback(
    async (version: DriveFileVersion) => {
      if (backend && file) {
        try {
          await backend.adopt(file, version);
        } catch (error) {
          toast.error(messages.drive_versions_keep_failed_title(), {
            description:
              error instanceof Error && error.message
                ? error.message
                : messages.drive_node_rejected_description(),
            id: `comma-drive-version-${fileId}`,
            testId: `comma-drive-version-${fileId}`,
          });
          return;
        }
      }
      const settled = store.resolveFileVersion(fileId, version.id);
      if (!settled) return;
      if (backend) await refreshDrive(store, backend).catch(() => undefined);
      const device =
        store.getSnapshot().devices.find((entry) => entry.id === version.deviceId)
          ?.label ?? version.deviceId;
      toast.success(messages.drive_versions_kept_title({ device }), {
        description: messages.drive_versions_kept_description({
          fileName: settled.name,
        }),
        id: `comma-drive-version-${fileId}`,
        testId: `comma-drive-version-${fileId}`,
      });
    },
    [backend, file, fileId, messages, store]
  );

  const copyImage = useCallback(async () => {
    if (!file?.blob) return;
    try {
      await copyImageBlob(file.blob);
    } catch {
      // A clipboard that refused the image used to fail silently; say so.
      toast.error(messages.drive_preview_copy_failed_title(), {
        description: messages.drive_preview_copy_failed_description({
          name: file.name,
        }),
        id: "comma-drive-preview-copy",
        testId: "comma-drive-preview-copy",
      });
      return;
    }
    setCopied(true);
    if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
    copiedTimerRef.current = setTimeout(() => setCopied(false), 1400);
    toast.success(messages.drive_preview_copied_title(), {
      description: messages.drive_preview_copied_description({ name: file.name }),
      id: "comma-drive-preview-copy",
      testId: "comma-drive-preview-copy",
    });
  }, [file, messages]);

  if (!file || !download) return null;

  const spaceName =
    snapshot.spaces.find((space) => space.id === file.spaceId)?.name ?? file.spaceId;
  const deviceLabel =
    snapshot.devices.find((device) => device.id === file.deviceId)?.label ??
    file.deviceId;
  const copyable = driveFileKind(file) === "image" && file.blob !== undefined;

  return (
    <FilePreviewPanel
      fileName={file.name}
      mimeType={file.blob?.type}
      blob={file.blob}
      error={
        !file.blob && failure?.sourceKey === sourceKey ? failure.message : undefined
      }
      placeholder={!backend ? messages.drive_preview_not_synced() : undefined}
      panelId={panelId}
      testId="drive-preview-panel"
      download={download}
      openIn={openIn}
      onOpenBrowser={onOpenBrowser}
      onAttachFiles={onAttachFiles}
      extraActions={
        copyable ? (
          <Tooltip
            content={
              copied
                ? messages.drive_preview_copied()
                : messages.drive_preview_copy_image()
            }
            placement="bottom"
          >
            <ShellIconButtonControl
              aria-label={messages.drive_preview_copy_image()}
              data-testid="drive-preview-copy"
              icon={
                copied ? (
                  <CheckIcon className="comma-input-icon text-fg-success-primary" />
                ) : (
                  <CopyIcon className="comma-input-icon" />
                )
              }
              onPress={() => void copyImage()}
            />
          </Tooltip>
        ) : null
      }
    >
      <dl className="m-0 flex w-full flex-col gap-md p-xl">
        <DrivePreviewMetaRow
          label={messages.drive_preview_meta_space()}
          value={spaceName}
        />
        <DrivePreviewMetaRow
          label={messages.drive_preview_meta_path()}
          value={file.name}
        />
        <DrivePreviewMetaRow
          label={messages.drive_preview_meta_size()}
          value={formatDriveFileSize(file.sizeBytes)}
        />
        <DrivePreviewMetaRow
          label={messages.drive_preview_meta_modified()}
          value={formatDate(file.modifiedAt, locale, {
            dateStyle: "medium",
            hourCycle: "h23",
            timeStyle: "short",
          })}
        />
        <DrivePreviewMetaRow
          label={messages.drive_preview_meta_device()}
          value={deviceLabel}
        />
        <DrivePreviewMetaRow
          label={messages.drive_preview_meta_contents()}
          value={file.contentsHash}
        />
      </dl>
      {/* Last, under everything the file is: a reader takes in the file
              first, and only then the choice about which copy of it to keep. */}
      <DriveVersionsPanel
        devices={snapshot.devices}
        file={file}
        onKeep={(version) => void keepVersion(version)}
        ownDeviceId={snapshot.devices.find((device) => device.current)?.id}
        writable={
          snapshot.spaces.find((space) => space.id === file.spaceId)?.writable !== false
        }
      />
    </FilePreviewPanel>
  );
}
