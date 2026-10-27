import type { AttachmentUploadInput } from "@comma/core/chat";
import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { useCall } from "@comma/core-client";
import { CheckIcon, CopyIcon, EditBigIcon } from "@comma/ui/components/icons";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { type ChatPanelMediaDownloadAction } from "@comma/ui/components/chat-panel";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ShellIconButtonControl } from "../ShellIconButton";
import { DriveVersionsPanel } from "./DriveVersionsPanel";
import {
  driveFileKind,
  driveStreamMediaType,
  driveSystemSpaceId,
  formatDriveFileSize,
  getDriveStore,
  useDriveSnapshot,
  type DriveFileVersion,
} from "./driveStore";
import {
  driveNodeAvailable,
  ensureDriveFileBlob,
  ensureDriveFileVersions,
  openDriveStream,
} from "./driveBackend";
import { downloadDriveFile } from "./driveTransfers";
import { DriveFileEditor } from "./DriveFileEditor";
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
  const call = useCall();
  // A System Files entry comes from Comma; nothing about it is the node's. This device's node streams media.
  const system = file?.system !== undefined;
  const node = !system && driveNodeAvailable();
  // `hash`: the content the editor opened with, which the save names as its
  // precondition; a reload of the listing while editing does not move it.
  const [editing, setEditing] = useState<{
    fileId: string;
    hash: string | undefined;
    text: string;
  }>();
  const editable = system && file?.writable === true;
  const hasBlob = file?.blob !== undefined;
  const sourceKey = file
    ? JSON.stringify([file.id, file.deviceId, file.contentsHash])
    : fileId;
  const [failure, setFailure] = useState<{ sourceKey: string; message: string }>();
  const [stream, setStream] = useState<{ sourceKey: string; url: string }>();
  const kind = file ? driveFileKind(file) : undefined;
  // Audio and video play from a ranged stream; nothing else needs them whole.
  const streamable = kind === "audio" || kind === "video";
  const wantsVersions =
    file !== undefined && file.versions === undefined && (file.versionCount ?? 1) > 1;
  // The node holds the bytes and the copies; the panel asks for them on open
  // and again should a reload of the listing drop them.
  useEffect(() => {
    const current = store.getSnapshot().files.find((entry) => entry.id === fileId);
    if (!current) return;
    let active = true;
    const failed = () => {
      if (active) setFailure({ sourceKey, message: messages.file_preview_failed() });
    };
    if (current.blob === undefined && streamable && node) {
      void openDriveStream(current, driveStreamMediaType(current.name)).then((url) => {
        if (active) setStream({ sourceKey, url });
      }, failed);
    } else if (current.blob === undefined) {
      void ensureDriveFileBlob(store, call, current).catch(failed);
    }
    if (node && current.versions === undefined && (current.versionCount ?? 1) > 1) {
      void ensureDriveFileVersions(call, current).catch(() => {});
    }
    return () => {
      active = false;
    };
  }, [
    call,
    node,
    fileId,
    sourceKey,
    hasBlob,
    streamable,
    wantsVersions,
    store,
    messages,
  ]);
  const [copied, setCopied] = useState(false);
  const copiedTimerRef = useRef<CancelUiTimer | null>(null);

  useEffect(
    () => () => {
      if (copiedTimerRef.current) copiedTimerRef.current();
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
                (await downloadDriveFile(file, { call, bridge, locale }))
                  ? { status: "success" }
                  : { status: "error", code: "unknown", retryable: true },
            },
          }
        : undefined,
    [bridge, call, file, locale]
  );
  const blob = file?.blob;
  const fileName = file?.name;
  const selection = useMemo(
    () => ({ blob, fileId, fileName, signal: AbortSignal.abort() }),
    [blob, fileId, fileName]
  );
  useEffect(() => {
    // Effect setup owns the live signal, including StrictMode's setup replay.
    // Replace/Close retire this selection.
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
      if (!file) return;
      try {
        await call("drive.settle", { file: file.id, version: version.id });
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
      const device =
        store.getSnapshot().devices.find((entry) => entry.id === version.deviceId)
          ?.label ?? version.deviceId;
      toast.success(messages.drive_versions_kept_title({ device }), {
        description: messages.drive_versions_kept_description({ fileName: file.name }),
        id: `comma-drive-version-${fileId}`,
        testId: `comma-drive-version-${fileId}`,
      });
    },
    [call, file, fileId, messages, store]
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
    if (copiedTimerRef.current) copiedTimerRef.current();
    copiedTimerRef.current = uiClock.after(1400, () => setCopied(false));
    toast.success(messages.drive_preview_copied_title(), {
      description: messages.drive_preview_copied_description({ name: file.name }),
      id: "comma-drive-preview-copy",
      testId: "comma-drive-preview-copy",
    });
  }, [file, messages]);

  if (!file || !download) return null;

  if (editing?.fileId === file.id)
    return (
      <DriveFileEditor
        fileName={file.name}
        initialText={editing.text}
        onCancel={() => setEditing(undefined)}
        onSave={async (text) => {
          try {
            await call("drive.write", {
              space: driveSystemSpaceId,
              ...(file.folderPath ? { folderPath: file.folderPath } : {}),
              name: file.name,
              bytes: new TextEncoder().encode(text),
              ...(editing.hash ? { expectedHash: editing.hash } : {}),
            });
          } catch (error) {
            const { code, detail } = (error ?? {}) as {
              code?: unknown;
              detail?: { hash?: string };
            };
            const changed = code === "changed";
            // The refusal names the version the core now holds; a save after
            // reading this message is meant to replace that one.
            if (changed)
              setEditing((current) => current && { ...current, hash: detail?.hash });
            toast.error(messages.drive_editor_save_failed_title(), {
              description: changed
                ? messages.drive_editor_changed_description({ name: file.name })
                : messages.drive_editor_save_failed_description({ name: file.name }),
              id: `comma-drive-save-${file.id}`,
              testId: `comma-drive-save-${file.id}`,
            });
            throw error;
          }
          setEditing(undefined);
          toast.success(messages.drive_editor_saved_title(), {
            description: messages.drive_editor_saved_description({ name: file.name }),
            id: `comma-drive-save-${file.id}`,
            testId: `comma-drive-save-${file.id}`,
          });
        }}
        panelId={panelId}
      />
    );

  const spaceName =
    snapshot.spaces.find((space) => space.id === file.spaceId)?.name ?? file.spaceId;
  const deviceLabel =
    snapshot.devices.find((device) => device.id === file.deviceId)?.label ??
    file.deviceId;
  const copyable = kind === "image" && file.blob !== undefined;

  return (
    <FilePreviewPanel
      fileName={file.name}
      mimeType={file.blob?.type}
      blob={file.blob}
      mediaUrl={stream?.sourceKey === sourceKey ? stream.url : undefined}
      error={
        !file.blob && failure?.sourceKey === sourceKey ? failure.message : undefined
      }
      panelId={panelId}
      testId="drive-preview-panel"
      download={download}
      openIn={openIn}
      onOpenBrowser={onOpenBrowser}
      onAttachFiles={onAttachFiles}
      extraActions={
        editable ? (
          <Tooltip content={messages.drive_editor_edit()} placement="bottom">
            <ShellIconButtonControl
              aria-label={messages.drive_editor_edit()}
              data-testid="drive-preview-edit"
              icon={<EditBigIcon className="comma-input-icon" />}
              isDisabled={!blob}
              onPress={() => {
                const hash =
                  file.system && file.system.kind !== "skill"
                    ? file.system.hash
                    : undefined;
                void blob
                  ?.text()
                  .then((text) => setEditing({ fileId: file.id, hash, text }));
              }}
            />
          </Tooltip>
        ) : copyable ? (
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
          value={file.system?.kind === "vfs" ? file.system.path : file.name}
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
        {system ? null : (
          <>
            <DrivePreviewMetaRow
              label={messages.drive_preview_meta_device()}
              value={deviceLabel}
            />
            <DrivePreviewMetaRow
              label={messages.drive_preview_meta_contents()}
              value={file.contentsHash}
            />
          </>
        )}
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
