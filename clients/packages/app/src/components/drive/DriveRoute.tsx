import { useApplicationMenu } from "../application-menu/useApplicationMenu";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { AiInputDropOverlay, ContentHeader, toast } from "@comma/ui";
import { useNavigate, useSearch } from "@tanstack/react-router";
import {
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { revealLabel } from "../../runtime-files/fileDownloads";
import { commaDriveSpaceRailWidth } from "../shellGeometry";
import { useCommaAuth } from "../auth-context";
import {
  driveSidebarHost,
  useChatSidebar,
  useRegisterChatSidebarHost,
} from "../chat-sidebar/ChatSidebarContext";
import { isStaleChatSessionError, useChatRegistry } from "../chat/ChatProvider";
import type { AttachmentUploadInput } from "../chat/model/conversationChannel";
import {
  isAllowedAttachment,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS_PER_MESSAGE,
} from "../chat/model/protocol";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import type { DriveFileMenuAction } from "./DriveFileMenu";
import { driveVersionCount } from "./driveStore";
import { driveSpacesRoot } from "./driveSynchronicityBackend";
import { DriveFileList } from "./DriveFileList";
import { DriveSelectionBar } from "./DriveSelectionBar";
import { DriveDeleteDialog } from "./DriveDeleteDialog";
import { DriveFolderNameDialog } from "./DriveFolderNameDialog";
import {
  DriveSpaceRail,
  type DriveRailMenuAction,
  type DriveSpaceMenuAction,
} from "./DriveSpaceRail";
import { DriveSyncFoldersDialog } from "./DriveSyncFoldersDialog";
import { DriveSyncHistoryDialog } from "./DriveSyncHistoryDialog";
import { DriveStopSharingDialog } from "./DriveStopSharingDialog";
import { DriveToolbar } from "./DriveToolbar";
import { DriveTransferPanel } from "./DriveTransferPanel";
import {
  getDriveStore,
  useDriveSnapshot,
  type DriveFile,
  type DriveSpace,
  type DriveTransfer,
} from "./driveStore";
import {
  downloadDriveFile,
  downloadDriveFiles,
  retryDriveTransfer,
  revealDriveDownload,
  uploadDriveFiles,
} from "./driveTransfers";
import {
  enrollDriveDevice,
  ensureDriveFileBlob,
  ensureDriveFileThumbnail,
  getDriveBackend,
  refreshDrive,
  restartDrive,
  useDriveBackendLoad,
} from "./driveBackend";
import { useDriveFileReveal } from "./useDriveFileReveal";
import { collectDroppedFiles, useDriveDropZone } from "./driveDropZone";

export function DriveRoute() {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const registry = useChatRegistry();
  const store = getDriveStore();
  const snapshot = useDriveSnapshot(store);
  const bridge = getNativeBridge();
  const canReveal = bridge.platform === "electron";
  const fileRevealLabel = canReveal ? revealLabel(bridge.os, locale) : undefined;
  const backend = getDriveBackend();
  const revealSearch = useSearch({ strict: false });
  const routeRef = useRef<HTMLElement>(null);
  const transferDeps = useMemo(
    () => ({ ...(backend ? { backend } : {}), bridge, locale }),
    [backend, bridge, locale]
  );
  const { api } = useCommaAuth();
  // Enrollment is opportunistic: a Workspace without a network yet, or no
  // connection, leaves the node on its own key and the next launch tries again.
  useDriveBackendLoad(store, backend, (state) => {
    if (backend) void enrollDriveDevice(api, backend, state).catch(() => {});
  });
  const nodeRejected = useCallback(
    (title: string, error: unknown) => {
      toast.error(title, {
        description:
          error instanceof Error && error.message
            ? error.message
            : messages.drive_node_rejected_description(),
        id: "comma-drive-node-rejected",
        testId: "comma-drive-node-rejected",
      });
    },
    [messages]
  );

  const [selectedFileIds, setSelectedFileIds] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const [transfersOpen, setTransfersOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<readonly DriveFile[] | undefined>();
  // Where the list is inside the selected space. Its own history: stepping
  // into a folder never touches the app's route history.
  const [folderPath, setFolderPath] = useState<readonly string[]>([]);
  const clearRevealSearch = useCallback(() => {
    void navigate({ to: "/drive", search: {}, replace: true });
  }, [navigate]);
  const revealFileId = useDriveFileReveal({
    backend,
    folderPath,
    onConsumed: clearRevealSearch,
    rootRef: routeRef,
    search: revealSearch,
    setFolderPath,
    snapshot,
    store,
  });
  const [folderDialog, setFolderDialog] = useState<
    { kind: "create" } | { kind: "rename"; space: DriveSpace } | undefined
  >();
  const [syncPickerOpen, setSyncPickerOpen] = useState(false);
  const [syncHistoryOpen, setSyncHistoryOpen] = useState(false);
  const folderInputRef = useRef<HTMLInputElement | null>(null);
  const [stopSharingTarget, setStopSharingTarget] = useState<
    | { fileId: string; kind: "file"; name: string }
    | { kind: "space"; name: string; originPath?: string; spaceId: string }
    | undefined
  >();
  // The panel's X is "done with these": it hides the panel and marks the
  // finished rows for removal. The removal itself waits for the next open, so
  // the rows never vanish underneath the closing animation, and whatever
  // opens it next — the toolbar button or a fresh upload — starts clean.
  const transfersDismissed = useRef(false);
  const openTransfers = useCallback(() => {
    if (transfersDismissed.current) {
      transfersDismissed.current = false;
      store.dismissFinishedTransfers();
    }
    setTransfersOpen(true);
  }, [store]);
  const dismissTransfers = useCallback(() => {
    transfersDismissed.current = true;
    setTransfersOpen(false);
  }, []);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  // File previews are tabs of the shell's one right sidebar, not a second
  // sidebar: registering this host is what points that sidebar at Drive.
  const { closeDrivePreview, openDrivePreview } = useChatSidebar();
  useRegisterChatSidebarHost(driveSidebarHost);

  const currentDevice =
    snapshot.devices.find((device) => device.current) ?? snapshot.devices[0];
  const currentDeviceId = currentDevice?.id ?? "";
  const selectedSpace = snapshot.spaces.find(
    (space) => space.id === snapshot.selectedSpaceId
  );
  const selectedSpaceWritable = selectedSpace?.writable !== false;
  // The current device shows the whole unified tree; picking another device
  // pins the list to that origin's files, Synchronicity's `--select origin=`.
  const spaceFiles = useMemo(
    () =>
      snapshot.files.filter(
        (file) =>
          file.spaceId === snapshot.selectedSpaceId &&
          (snapshot.originDeviceId === currentDeviceId ||
            file.deviceId === snapshot.originDeviceId)
      ),
    [snapshot.files, snapshot.selectedSpaceId, snapshot.originDeviceId, currentDeviceId]
  );
  const openPreview = useCallback(
    (file: DriveFile) => {
      openDrivePreview(driveSidebarHost, { id: file.id, name: file.name });
    },
    [openDrivePreview]
  );

  const closePreviewTab = useCallback(
    (fileId: string) => {
      closeDrivePreview(driveSidebarHost, fileId);
    },
    [closeDrivePreview]
  );

  const runDownload = useCallback(
    (file: DriveFile) => {
      void downloadDriveFile(store, file, transferDeps);
    },
    [store, transferDeps]
  );

  const clearSelection = useCallback(() => {
    setSelectedFileIds(new Set());
  }, []);

  // Hands the selection to the Comma assistant as ordinary composer attachments.
  // The Home conversation is one registry channel keyed by group/conversation,
  // so attaching through a short-lived lease lands in the same draft the Home
  // composer renders once we navigate there.
  const askCommaAgent = useCallback(
    async (files: readonly DriveFile[]) => {
      const admitted: AttachmentUploadInput[] = [];
      let skipped = 0;
      for (const file of files) {
        // Bytes the node holds but this renderer has not read yet are fetched
        // here; the size gate comes first so an oversized file is never read.
        const blob =
          file.blob ??
          (backend && file.sizeBytes <= MAX_ATTACHMENT_BYTES
            ? await ensureDriveFileBlob(store, backend, file).catch(() => undefined)
            : undefined);
        const eligible =
          blob !== undefined &&
          blob.size <= MAX_ATTACHMENT_BYTES &&
          isAllowedAttachment(file.name) &&
          admitted.length < MAX_ATTACHMENTS_PER_MESSAGE;
        if (!eligible || blob === undefined) {
          skipped += 1;
          continue;
        }
        admitted.push({ data: blob, name: file.name, size: blob.size });
      }
      if (skipped > 0) {
        toast.warning(messages.drive_ask_comma_skipped({ count: String(skipped) }), {
          id: "comma-drive-ask-comma-skipped",
          testId: "comma-drive-ask-comma-skipped",
        });
      }
      if (admitted.length === 0) return;

      const attempt = registry.beginAttempt();
      try {
        await attempt.run(async (attemptApi, signal) => {
          let target = registry.getHomeConversationTarget();
          if (!target) {
            const resolution = await resolveWorkspaceChat({
              api: attemptApi,
              locale,
              session: registry.productLease,
              signal,
            });
            if (resolution.status !== "ready") {
              throw new Error(messages.chat_unavailable());
            }
            target = {
              conversationId: resolution.conversation.id,
              groupId: resolution.groupId,
              workspaceId: resolution.workspaceId,
            };
          }
          const lease = attempt.retain(
            target.workspaceId,
            target.groupId,
            target.conversationId
          );
          lease.channel.attachFiles(admitted);
          clearSelection();
          await navigate({ to: "/" });
        });
      } catch (error) {
        if (!isStaleChatSessionError(error)) {
          toast.error(messages.chat_unavailable(), {
            id: "comma-drive-ask-comma-failed",
            testId: "comma-drive-ask-comma-failed",
          });
        }
      } finally {
        attempt.release();
      }
    },
    [backend, clearSelection, locale, messages, navigate, registry, store]
  );

  const onFileMenuAction = useCallback(
    (action: DriveFileMenuAction, file: DriveFile) => {
      if (action === "ask-comma-agent") {
        void askCommaAgent([file]);
        return;
      }
      if (action === "download") {
        void downloadDriveFile(store, file, transferDeps);
        return;
      }
      if (action === "keep-offline") {
        const keepOffline = !(file.keepOffline ?? false);
        if (backend) {
          void backend
            .setKeepOffline(file, keepOffline)
            .then(() => {
              store.setKeepOffline(file.id, keepOffline);
              toast(
                keepOffline
                  ? messages.drive_keep_offline_on_title()
                  : messages.drive_keep_offline_off_title(),
                {
                  description: keepOffline
                    ? messages.drive_keep_offline_on_description({ name: file.name })
                    : messages.drive_keep_offline_off_description({ name: file.name }),
                  id: `comma-drive-keep-offline-${file.id}`,
                  testId: `comma-drive-keep-offline-${file.id}`,
                }
              );
            })
            .catch((error: unknown) =>
              nodeRejected(messages.drive_keep_offline_failed_title(), error)
            );
          return;
        }
        const updated = store.setKeepOffline(file.id, keepOffline);
        if (!updated) return;
        toast(
          keepOffline
            ? messages.drive_keep_offline_on_title()
            : messages.drive_keep_offline_off_title(),
          {
            description: keepOffline
              ? messages.drive_keep_offline_on_description({ name: file.name })
              : messages.drive_keep_offline_off_description({ name: file.name }),
            id: `comma-drive-keep-offline-${file.id}`,
            testId: `comma-drive-keep-offline-${file.id}`,
          }
        );
        return;
      }
      // Delete leaves the space on every device, so it is confirmed first;
      // the removal itself happens in `confirmDelete`.
      if (
        store.getSnapshot().spaces.find((space) => space.id === file.spaceId)
          ?.writable === false
      )
        return;
      setDeleteTarget([file]);
    },
    [askCommaAgent, backend, messages, nodeRejected, store, transferDeps]
  );

  const confirmDelete = useCallback(async () => {
    const files = deleteTarget;
    if (!files || files.length === 0) return;
    if (
      files.some(
        (file) =>
          store.getSnapshot().spaces.find((space) => space.id === file.spaceId)
            ?.writable === false
      )
    )
      return;
    if (backend) {
      try {
        await Promise.all(files.map((file) => backend.deleteFile(file)));
      } catch {
        toast.error(messages.drive_delete_failed_title(), {
          description: messages.drive_node_rejected_description(),
          id: "comma-drive-delete",
          testId: "comma-drive-delete",
        });
        return;
      }
    }
    for (const file of files) {
      store.removeFile(file.id);
      closePreviewTab(file.id);
    }
    setSelectedFileIds((fileIds) => {
      const next = new Set(fileIds);
      for (const file of files) next.delete(file.id);
      return next.size === fileIds.size ? fileIds : next;
    });
    setDeleteTarget(undefined);
    toast.success(messages.drive_delete_done_title(), {
      description:
        files.length === 1
          ? messages.drive_delete_done_one({ name: files[0]!.name })
          : messages.drive_delete_done_many({ count: String(files.length) }),
      id: "comma-drive-delete",
      testId: "comma-drive-delete",
    });
  }, [backend, closePreviewTab, deleteTarget, messages, store]);

  const onSpaceMenuAction = useCallback(
    (action: DriveSpaceMenuAction, space: DriveSpace) => {
      if (action === "rename") {
        setFolderDialog({ kind: "rename", space });
        return;
      }
      setStopSharingTarget({
        kind: "space",
        name: space.name,
        spaceId: space.id,
        ...(space.originPath === undefined ? {} : { originPath: space.originPath }),
      });
    },
    []
  );

  const syncSpaceOnNode = useCallback(
    async (space: DriveSpace, synced: boolean) => {
      if (!backend) return;
      // What the write will do is decided before it runs: the listing
      // already says which paths only other devices have (they land) and
      // which ones the cluster disagrees about (they are left, and recorded
      // as failed so the history can retry them with the cluster's version).
      const files = store
        .getSnapshot()
        .files.filter((file) => file.spaceId === space.id);
      const arriving = files.filter(
        (file) => file.deviceId !== store.getSnapshot().originDeviceId
      );
      const conflicts = files.filter((file) => driveVersionCount(file) > 1);
      const counts = await backend.setSpaceSynced(space, synced);
      await refreshDrive(store, backend);
      store.recordSyncHistory([
        {
          direction: "download",
          kind: "folder",
          name: space.name,
          operation: synced ? "added" : "removed",
          status: "success",
        },
        ...(synced && counts
          ? [
              ...arriving.slice(0, counts.adopt).map((file) => ({
                direction: "download" as const,
                kind: "file" as const,
                name: file.name,
                operation: "added" as const,
                sizeBytes: file.sizeBytes,
                status: "success" as const,
              })),
              ...conflicts.map((file) => ({
                direction: "download" as const,
                errorMessage: messages.drive_sync_history_conflict_reason(),
                fileId: file.id,
                kind: "file" as const,
                name: file.name,
                operation: "updated" as const,
                sizeBytes: file.sizeBytes,
                status: "failed" as const,
              })),
            ]
          : []),
      ]);
      return counts;
    },
    [backend, messages, store]
  );

  const onSpaceSyncedChange = useCallback(
    (space: DriveSpace, synced: boolean) => {
      if (backend) {
        void syncSpaceOnNode(space, synced)
          .then((counts) => {
            // A space this Mac publishes reports what it took in; one it
            // replicates is copied by the node as it goes, into its checkout.
            const onDescription = counts
              ? messages.drive_sync_space_on_description({
                  count: String(counts.adopt),
                })
              : messages.drive_sync_space_on_replica_description({
                  path: `${driveSpacesRoot(snapshot.localSyncRoot)}/${space.id}`,
                });
            toast(
              synced
                ? messages.drive_sync_space_on_title({ name: space.name })
                : messages.drive_sync_space_off_title({ name: space.name }),
              {
                description: synced
                  ? onDescription
                  : messages.drive_sync_space_off_description(),
                id: `comma-drive-space-sync-${space.id}`,
                testId: `comma-drive-space-sync-${space.id}`,
              }
            );
          })
          .catch((error: unknown) =>
            nodeRejected(messages.drive_sync_failed_title(), error)
          );
        return;
      }
      const result = store.setSpaceSynced(space.id, synced);
      if (!result) return;
      toast(
        synced
          ? messages.drive_sync_space_on_title({ name: space.name })
          : messages.drive_sync_space_off_title({ name: space.name }),
        {
          description: synced
            ? messages.drive_sync_space_on_description({ count: String(result.copied) })
            : messages.drive_sync_space_off_description(),
          id: `comma-drive-space-sync-${space.id}`,
          testId: `comma-drive-space-sync-${space.id}`,
        }
      );
    },
    [backend, messages, nodeRejected, snapshot.localSyncRoot, store, syncSpaceOnNode]
  );

  const onRailAction = useCallback(
    (action: DriveRailMenuAction) => {
      if (action !== "new-folder") {
        folderInputRef.current?.click();
        return;
      }
      if (!backend) {
        setFolderDialog({ kind: "create" });
        return;
      }
      // With a node, a new space is a folder on this Mac published to every
      // device: the folder is picked, and its name is the space's.
      void backend
        .addSpaceFromFolder()
        .then(async (added) => {
          if (!added) return;
          await refreshDrive(store, backend);
          store.selectSpace(added.id);
          setFolderPath([]);
          toast.success(messages.drive_space_added_title({ name: added.name }), {
            description: messages.drive_space_added_description({ path: added.path }),
            id: "comma-drive-space-added",
            testId: "comma-drive-space-added",
          });
        })
        .catch((error: unknown) =>
          nodeRejected(messages.drive_space_add_failed_title(), error)
        );
    },
    [backend, messages, nodeRejected, store]
  );

  const submitFolderName = useCallback(
    (name: string) => {
      const dialog = folderDialog;
      setFolderDialog(undefined);
      if (!dialog) return;
      if (dialog.kind === "create") {
        const space = store.addSpace(name);
        store.selectSpace(space.id);
        setFolderPath([]);
        return;
      }
      if (backend) {
        void backend
          .renameSpace(dialog.space, name)
          .then(() => refreshDrive(store, backend))
          .then(() => {
            toast.success(messages.drive_folder_renamed_title(), {
              description: messages.drive_space_renamed_description({
                from: dialog.space.name,
                to: name,
              }),
              id: "comma-drive-folder-renamed",
              testId: "comma-drive-folder-renamed",
            });
          })
          .catch((error: unknown) =>
            nodeRejected(messages.drive_rename_failed_title(), error)
          );
        return;
      }
      const renamed = store.renameSpace(dialog.space.id, name);
      if (renamed?.synced) {
        toast.success(messages.drive_folder_renamed_title(), {
          description: messages.drive_folder_renamed_description({
            from: dialog.space.name,
            to: name,
          }),
          id: "comma-drive-folder-renamed",
          testId: "comma-drive-folder-renamed",
        });
      }
    },
    [backend, folderDialog, messages, nodeRejected, store]
  );

  // Turning local sync on starts with choosing what to mirror; turning it
  // off applies at once and keeps each space's own flag for the next time.
  const onLocalSyncEnabledChange = useCallback(
    (enabled: boolean) => {
      if (enabled) {
        setSyncPickerOpen(true);
        return;
      }
      if (!backend) {
        store.setLocalSyncEnabled(false);
        return;
      }
      const mirrored = snapshot.spaces.filter((space) => space.synced === true);
      void Promise.all(mirrored.map((space) => syncSpaceOnNode(space, false))).catch(
        (error: unknown) => nodeRejected(messages.drive_sync_failed_title(), error)
      );
    },
    [backend, messages, nodeRejected, snapshot.spaces, store, syncSpaceOnNode]
  );

  const openLocalRoot = useCallback(() => {
    if (!backend) return;
    void backend
      .openLocalRoot()
      .then((opened) => {
        if (!opened) {
          nodeRejected(messages.drive_open_local_failed_title(), "");
        }
      })
      .catch((error: unknown) =>
        nodeRejected(messages.drive_open_local_failed_title(), error)
      );
  }, [backend, messages, nodeRejected]);

  const confirmStopSharing = useCallback(() => {
    const target = stopSharingTarget;
    if (!target) return;
    if (backend) {
      const space =
        target.kind === "space"
          ? snapshot.spaces.find((entry) => entry.id === target.spaceId)
          : undefined;
      const file = target.kind === "file" ? store.fileById(target.fileId) : undefined;
      const stop =
        target.kind === "file"
          ? file
            ? backend.deleteFile(file)
            : Promise.resolve()
          : space
            ? backend.removeSpace(space)
            : Promise.resolve();
      void stop
        .then(() => refreshDrive(store, backend))
        .then(() => {
          if (target.kind === "file") closePreviewTab(target.fileId);
          else {
            for (const entry of snapshot.files) {
              if (entry.spaceId === target.spaceId) closePreviewTab(entry.id);
            }
          }
          setStopSharingTarget(undefined);
          toast.success(messages.drive_stop_sharing_done_title(), {
            description: messages.drive_stop_sharing_done_description({
              name: target.name,
            }),
            id: "comma-drive-stop-sharing",
            testId: "comma-drive-stop-sharing",
          });
        })
        .catch((error: unknown) =>
          nodeRejected(messages.drive_stop_sharing_failed_title(), error)
        );
      return;
    }
    if (target.kind === "file") {
      store.removeFile(target.fileId);
      closePreviewTab(target.fileId);
      setSelectedFileIds((fileIds) => {
        if (!fileIds.has(target.fileId)) return fileIds;
        const next = new Set(fileIds);
        next.delete(target.fileId);
        return next;
      });
    } else {
      for (const file of snapshot.files) {
        if (file.spaceId === target.spaceId) closePreviewTab(file.id);
      }
      store.removeSpace(target.spaceId);
    }
    setStopSharingTarget(undefined);
    toast.success(messages.drive_stop_sharing_done_title(), {
      description: messages.drive_stop_sharing_done_description({ name: target.name }),
      id: "comma-drive-stop-sharing",
      testId: "comma-drive-stop-sharing",
    });
  }, [
    backend,
    closePreviewTab,
    messages,
    nodeRejected,
    snapshot.files,
    snapshot.spaces,
    stopSharingTarget,
    store,
  ]);

  const onToggleSelected = useCallback((file: DriveFile, selected: boolean) => {
    setSelectedFileIds((fileIds) => {
      const next = new Set(fileIds);
      if (selected) {
        next.add(file.id);
      } else {
        next.delete(file.id);
      }
      return next;
    });
  }, []);

  // The composer's drop, aimed at a folder: what lands on the list goes
  // into the folder that is open, and a dropped folder keeps its shape
  // under it.
  const onDroppedFiles = useCallback(
    (transfer: DataTransfer) => {
      if (!selectedSpaceWritable) return;
      void collectDroppedFiles(transfer).then((dropped) => {
        if (dropped.length === 0) return;
        openTransfers();
        const byDir = new Map<string, File[]>();
        for (const { file, relativeDir } of dropped) {
          byDir.set(relativeDir, [...(byDir.get(relativeDir) ?? []), file]);
        }
        for (const [relativeDir, files] of byDir) {
          const target = [
            ...folderPath,
            ...(relativeDir ? relativeDir.split("/") : []),
          ];
          void uploadDriveFiles(
            store,
            files,
            {
              deviceId: currentDeviceId,
              ...(target.length > 0 ? { folderPath: target.join("/") } : {}),
              spaceId: snapshot.selectedSpaceId,
            },
            transferDeps
          );
        }
      });
    },
    [
      currentDeviceId,
      folderPath,
      openTransfers,
      snapshot.selectedSpaceId,
      store,
      transferDeps,
      selectedSpaceWritable,
    ]
  );
  const dropZone = useDriveDropZone(onDroppedFiles, selectedSpaceWritable);
  const dropTargetName =
    folderPath.at(-1) ??
    snapshot.spaces.find((space) => space.id === snapshot.selectedSpaceId)?.name ??
    "";

  const onPickedFiles = useCallback(
    (fileList: FileList | null) => {
      if (!selectedSpaceWritable) return;
      const sources = Array.from(fileList ?? []);
      if (sources.length === 0) return;
      openTransfers();
      void uploadDriveFiles(
        store,
        sources,
        {
          deviceId: currentDeviceId,
          ...(folderPath.length > 0 ? { folderPath: folderPath.join("/") } : {}),
          spaceId: snapshot.selectedSpaceId,
        },
        transferDeps
      );
    },
    [
      currentDeviceId,
      folderPath,
      openTransfers,
      snapshot.selectedSpaceId,
      store,
      transferDeps,
      selectedSpaceWritable,
    ]
  );

  const onRetryTransfer = useCallback(
    (transfer: DriveTransfer) => {
      void retryDriveTransfer(
        store,
        transfer.id,
        { deviceId: currentDeviceId, spaceId: snapshot.selectedSpaceId },
        transferDeps
      );
    },
    [currentDeviceId, snapshot.selectedSpaceId, store, transferDeps]
  );

  const onRevealTransfer = useCallback(
    (transfer: DriveTransfer) => {
      if (transfer.downloadRef === undefined) return;
      revealDriveDownload(bridge, transfer.downloadRef, transfer.fileName, locale);
    },
    [bridge, locale]
  );

  const openFilePicker = useCallback(() => {
    fileInputRef.current?.click();
  }, []);

  const selectedFiles = spaceFiles.filter((file) => selectedFileIds.has(file.id));
  const hasSelection = selectedFiles.length > 0;
  const [spaceRailCollapsed, setSpaceRailCollapsed] = useState(false);
  useLayoutEffect(() => {
    if (!hasSelection) return;
    const route = routeRef.current;
    const bar = route?.querySelector<HTMLElement>('[data-slot="selection-bar"]');
    if (!route || !bar) return;
    const measure = () => {
      // Compare against the pane WITH the rail, even while it is hidden. Using
      // the expanded pane here would toggle the rail on every resize delivery.
      setSpaceRailCollapsed(
        bar.offsetWidth > route.clientWidth - commaDriveSpaceRailWidth
      );
    };
    measure();
    // Two fixed elements per mounted Drive route; no per-file observation.
    const observer = new ResizeObserver(measure);
    observer.observe(route);
    observer.observe(bar);
    return () => observer.disconnect();
  }, [hasSelection]);

  const onToggleFiles = useCallback(
    (files: readonly DriveFile[], selected: boolean) => {
      setSelectedFileIds((fileIds) => {
        const next = new Set(fileIds);
        for (const file of files) {
          if (selected) next.add(file.id);
          else next.delete(file.id);
        }
        return next;
      });
    },
    []
  );

  // The rows land in the transfer panel, so open it for the batch the way a
  // fresh upload does; the selection has done its job once the downloads start.
  const downloadSelected = useCallback(() => {
    if (selectedFiles.length === 0) return;
    openTransfers();
    void downloadDriveFiles(store, selectedFiles, transferDeps);
    clearSelection();
  }, [clearSelection, openTransfers, selectedFiles, store, transferDeps]);

  // Mixed selections pin: the action only unpins once every file is already
  // pinned, so the label always names what the press will do.
  const selectionKeptOffline =
    selectedFiles.length > 0 &&
    selectedFiles.every((file) => file.keepOffline ?? false);

  const keepOfflineSelected = useCallback(() => {
    if (selectedFiles.length === 0) return;
    const keepOffline = !selectionKeptOffline;
    if (backend) {
      const changing = selectedFiles.filter(
        (file) => (file.keepOffline ?? false) !== keepOffline
      );
      void Promise.all(
        changing.map((file) => backend.setKeepOffline(file, keepOffline))
      )
        .then(() => {
          store.setKeepOfflineMany(
            new Set(changing.map((file) => file.id)),
            keepOffline
          );
          toast(
            keepOffline
              ? messages.drive_keep_offline_on_title()
              : messages.drive_keep_offline_off_title(),
            {
              description: keepOffline
                ? messages.drive_keep_offline_on_many({
                    count: String(changing.length),
                  })
                : messages.drive_keep_offline_off_many({
                    count: String(changing.length),
                  }),
              id: "comma-drive-keep-offline-selection",
              testId: "comma-drive-keep-offline-selection",
            }
          );
        })
        .catch((error: unknown) =>
          nodeRejected(messages.drive_keep_offline_failed_title(), error)
        );
      return;
    }
    const changed = store.setKeepOfflineMany(
      new Set(selectedFiles.map((file) => file.id)),
      keepOffline
    );
    if (changed === 0) return;
    toast(
      keepOffline
        ? messages.drive_keep_offline_on_title()
        : messages.drive_keep_offline_off_title(),
      {
        description: keepOffline
          ? messages.drive_keep_offline_on_many({ count: String(changed) })
          : messages.drive_keep_offline_off_many({ count: String(changed) }),
        id: "comma-drive-keep-offline-selection",
        testId: "comma-drive-keep-offline-selection",
      }
    );
  }, [backend, messages, nodeRejected, selectedFiles, selectionKeptOffline, store]);

  // The bar's and the selection menu's Delete both go through the same sheet.
  const deleteSelected = useCallback(() => {
    if (selectedSpaceWritable && selectedFiles.length > 0)
      setDeleteTarget(selectedFiles);
  }, [selectedFiles, selectedSpaceWritable]);

  useApplicationMenu([
    { id: "drive-upload", enabled: selectedSpaceWritable, run: openFilePicker },
    {
      id: "drive-upload-folder",
      enabled: selectedSpaceWritable,
      run: () => folderInputRef.current?.click(),
    },
    {
      id: "drive-add-folder",
      enabled: Boolean(backend),
      run: () => onRailAction("new-folder"),
    },
    { id: "drive-download", enabled: selectedFiles.length > 0, run: downloadSelected },
  ]);
  return (
    <section
      aria-label={messages.drive_region()}
      className="relative flex h-full min-h-0 w-full min-w-0 flex-1 bg-main-panel-bg"
      data-testid="drive-route"
      ref={routeRef}
    >
      <div className="flex min-w-0 flex-1 flex-col">
        {/* The toolbar is the header: the sidebar entry already names the
            route, so the row carries the controls instead of a title. The
            header's own right padding already reserves the global sidebar
            toggle's column and leaves a `lg` gap before it; pulling the
            toolbar back by `xs` lands Add files `md` (8px) from the toggle. */}
        {/* No padding override here: the header's own `padding-inline-start`
            is `max(xl, --comma-content-header-leading-inset)`, and that inset is
            what keeps the row clear of the macOS window controls once the
            sidebar collapses. A `pl-*` utility outranks it and puts the
            toolbar under the traffic lights. */}
        <ContentHeader>
          <DriveToolbar
            className="-mr-xs flex-1"
            devices={snapshot.devices}
            localSyncEnabled={snapshot.localSyncEnabled}
            localSyncRoot={snapshot.localSyncRoot}
            onLocalSyncEnabledChange={onLocalSyncEnabledChange}
            onOpenLocalRoot={openLocalRoot}
            onOpenSyncHistory={() => setSyncHistoryOpen(true)}
            onSelectDevice={(deviceId) => {
              store.setOriginDevice(deviceId);
              if (backend) void refreshDrive(store, backend).catch(() => undefined);
            }}
            onSelectVersionPolicy={(policy) => {
              store.setVersionPolicy(policy);
              // The node's listing is what the policy selects, so it is re-read under the new one.
              if (backend) void refreshDrive(store, backend).catch(() => {});
            }}
            onToggleTransfers={() =>
              transfersOpen ? setTransfersOpen(false) : openTransfers()
            }
            onUploadFiles={openFilePicker}
            onUploadFolder={() => folderInputRef.current?.click()}
            originDeviceId={snapshot.originDeviceId}
            versionPolicy={snapshot.versionPolicy}
            writable={selectedSpaceWritable}
          />
        </ContentHeader>
        {/* The space rail runs the full body height beside the list. */}
        <div className="flex min-h-0 min-w-0 flex-1">
          <div
            className="comma-drive-space-rail-slot"
            data-folded={hasSelection && spaceRailCollapsed ? "true" : "false"}
            inert={hasSelection && spaceRailCollapsed}
            style={
              {
                "--comma-drive-space-rail-width": `${commaDriveSpaceRailWidth}px`,
              } as CSSProperties
            }
          >
            <DriveSpaceRail
              onMenuAction={onSpaceMenuAction}
              onRailAction={onRailAction}
              onSelect={(spaceId) => {
                store.selectSpace(spaceId);
                setFolderPath([]);
              }}
              onSyncedChange={onSpaceSyncedChange}
              selectedSpaceId={snapshot.selectedSpaceId}
              spaces={snapshot.spaces}
            />
          </div>
          <div
            className="relative flex min-h-0 min-w-0 flex-1 flex-col"
            data-drop-active={dropZone.active ? "true" : undefined}
            data-testid="drive-file-pane"
            {...dropZone.handlers}
          >
            <DriveFileList
              files={spaceFiles}
              revealFileId={revealFileId}
              folderPath={folderPath}
              onDownload={runDownload}
              onNavigate={setFolderPath}
              onMenuAction={onFileMenuAction}
              onOpen={openPreview}
              onSelectionMenuAction={(action) => {
                if (action === "ask-comma-agent") void askCommaAgent(selectedFiles);
                else if (action === "download-all") downloadSelected();
                else if (action === "keep-offline") keepOfflineSelected();
                else deleteSelected();
              }}
              onToggleFiles={onToggleFiles}
              onToggleSelected={onToggleSelected}
              onNeedThumbnail={
                backend
                  ? (file) =>
                      void ensureDriveFileThumbnail(store, backend, file).catch(
                        () => {}
                      )
                  : undefined
              }
              onRetryNode={() => {
                if (backend) {
                  void restartDrive(store, backend).catch((error: unknown) =>
                    nodeRejected(messages.drive_node_error_title(), error)
                  );
                }
              }}
              onUploadFiles={openFilePicker}
              node={snapshot.node}
              selectedFileIds={selectedFileIds}
              selecting={selectedFiles.length > 0}
              selectionKeptOffline={selectionKeptOffline}
              spaceName={
                snapshot.spaces.find((space) => space.id === snapshot.selectedSpaceId)
                  ?.name ?? ""
              }
              writable={selectedSpaceWritable}
            />
            {selectedFiles.length > 0 ? (
              <DriveSelectionBar
                count={selectedFiles.length}
                onAskCommaAgent={() => void askCommaAgent(selectedFiles)}
                onClear={clearSelection}
                onDelete={deleteSelected}
                onDownloadAll={downloadSelected}
                writable={selectedSpaceWritable}
              />
            ) : null}
            {/* The same overlay the composer shows: one drop target across
                the app, this one naming the folder the files will land in. */}
            <AiInputDropOverlay
              active={dropZone.active}
              subtitle={messages.drive_drop_hint({ name: dropTargetName })}
              title={messages.drive_drop_title()}
            />
          </div>
        </div>
      </div>
      {deleteTarget ? (
        <DriveDeleteDialog
          files={deleteTarget}
          onClose={() => setDeleteTarget(undefined)}
          onConfirm={() => void confirmDelete()}
        />
      ) : null}
      {folderDialog ? (
        <DriveFolderNameDialog
          existingNames={snapshot.spaces.map((space) => space.name)}
          location={snapshot.localSyncRoot}
          mode={
            folderDialog.kind === "create"
              ? { kind: "create" }
              : { currentName: folderDialog.space.name, kind: "rename" }
          }
          onClose={() => setFolderDialog(undefined)}
          onSubmit={submitFolderName}
          {...(folderDialog.kind === "rename"
            ? { synced: folderDialog.space.synced ?? false }
            : {})}
        />
      ) : null}
      {syncHistoryOpen ? (
        <DriveSyncHistoryDialog
          entries={snapshot.syncHistory}
          onClose={() => setSyncHistoryOpen(false)}
          onRetryFailures={() => {
            if (!backend) {
              store.retryFailedSync();
              return;
            }
            // The cluster's version, taken for every conflict still open.
            const open = snapshot.syncHistory.filter(
              (entry) =>
                entry.status === "failed" &&
                entry.resolved !== true &&
                entry.fileId !== undefined
            );
            const files = open.flatMap((entry) => {
              const file =
                entry.fileId === undefined ? undefined : store.fileById(entry.fileId);
              return file ? [file] : [];
            });
            void Promise.all(files.map((file) => backend.adoptNewest(file)))
              .then(() => refreshDrive(store, backend))
              .then(() => {
                store.markSyncResolved(new Set(open.map((entry) => entry.id)));
                store.recordSyncHistory(
                  files.map((file) => ({
                    direction: "download" as const,
                    kind: "file" as const,
                    name: file.name,
                    operation: "updated" as const,
                    sizeBytes: file.sizeBytes,
                    status: "success" as const,
                  }))
                );
              })
              .catch((error: unknown) =>
                nodeRejected(messages.drive_sync_failed_title(), error)
              );
          }}
        />
      ) : null}
      {syncPickerOpen ? (
        <DriveSyncFoldersDialog
          onClose={() => setSyncPickerOpen(false)}
          onConfirm={async (spaceIds) => {
            const selected = snapshot.spaces.filter((space) => spaceIds.has(space.id));
            if (selected.length === 0) return;
            try {
              if (backend) {
                const changes = snapshot.spaces.filter(
                  (space) => Boolean(space.synced) !== spaceIds.has(space.id)
                );
                const results = await Promise.allSettled(
                  changes.map((space) => syncSpaceOnNode(space, spaceIds.has(space.id)))
                );
                await refreshDrive(store, backend);
                const failed = results.find((result) => result.status === "rejected");
                if (failed?.status === "rejected") throw failed.reason;
              } else {
                store.setLocalSyncEnabled(true, spaceIds);
              }
              setSyncPickerOpen(false);
              toast.success(messages.drive_sync_started_title(), {
                description: messages.drive_sync_started_description({
                  count: String(selected.length),
                  path: backend
                    ? selected
                        .map(
                          (space) =>
                            space.originPath ||
                            `${driveSpacesRoot(snapshot.localSyncRoot)}/${space.id}`
                        )
                        .join(", ")
                    : snapshot.localSyncRoot,
                }),
                id: "comma-drive-sync-started",
                testId: "comma-drive-sync-started",
              });
            } catch (error) {
              nodeRejected(messages.drive_sync_failed_title(), error);
            }
          }}
          sizeOf={(spaceId) => store.spaceSizeBytes(spaceId)}
          spaces={snapshot.spaces}
        />
      ) : null}
      {stopSharingTarget ? (
        <DriveStopSharingDialog
          onClose={() => setStopSharingTarget(undefined)}
          onConfirm={confirmStopSharing}
          target={
            stopSharingTarget.kind === "file"
              ? { kind: "file", name: stopSharingTarget.name }
              : {
                  kind: "space",
                  name: stopSharingTarget.name,
                  ...(stopSharingTarget.originPath === undefined
                    ? {}
                    : { originPath: stopSharingTarget.originPath }),
                }
          }
        />
      ) : null}
      <DriveTransferPanel
        onClose={dismissTransfers}
        onRetry={onRetryTransfer}
        onReveal={canReveal ? onRevealTransfer : undefined}
        open={transfersOpen}
        revealActionLabel={fileRevealLabel}
        transfers={snapshot.transfers}
      />
      <input
        aria-hidden
        className="hidden"
        multiple
        onChange={(event) => {
          onPickedFiles(event.currentTarget.files);
          event.currentTarget.value = "";
        }}
        ref={fileInputRef}
        tabIndex={-1}
        type="file"
      />
      {/* A directory picker: the browser hands back every file inside with
          its path, which the upload turns into folders under the space. */}
      <input
        aria-hidden
        className="hidden"
        data-testid="drive-folder-input"
        multiple
        onChange={(event) => {
          onPickedFiles(event.currentTarget.files);
          event.currentTarget.value = "";
        }}
        ref={folderInputRef}
        tabIndex={-1}
        type="file"
        // @ts-expect-error -- non-standard but the only way to pick a directory
        webkitdirectory=""
      />
    </section>
  );
}
