import { useApplicationMenu } from "../application-menu/useApplicationMenu";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { AiInputDropOverlay } from "@comma/ui/components/ai-input";
import { ContentHeader } from "@comma/ui/components/content-header";
import { toast } from "@comma/ui/components/toast";
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
import { useCall } from "@comma/core-client";
import {
  driveSidebarHost,
  useChatSidebar,
  useRegisterChatSidebarHost,
} from "../chat-sidebar/ChatSidebarContext";
import { isStaleChatSessionError, useChatRegistry } from "../chat/ChatProvider";
import type { AttachmentUploadInput } from "@comma/core/chat";
import {
  isAllowedAttachment,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS_PER_MESSAGE,
} from "@comma/core/chat";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import type { DriveFileMenuAction } from "./DriveFileMenu";
import { driveFileWritable, driveSpacesRoot } from "./driveStore";
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
  driveNodeAvailable,
  ensureDriveFileBlob,
  ensureDriveFileThumbnail,
  openDriveLocalRoot,
  useDriveRefreshOnFocus,
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
  // This device's node: Drive can change here. Without one (the web), it only reads.
  const node = driveNodeAvailable();
  const revealSearch = useSearch({ strict: false });
  const routeRef = useRef<HTMLElement>(null);
  const call = useCall();
  const transferDeps = useMemo(
    () => ({ call, bridge, locale }),
    [bridge, call, locale]
  );
  useDriveRefreshOnFocus(call, true);
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
    call,
    folderPath,
    onConsumed: clearRevealSearch,
    rootRef: routeRef,
    search: revealSearch,
    setFolderPath,
    snapshot,
    store,
  });
  const [folderDialog, setFolderDialog] = useState<{ space: DriveSpace } | undefined>();
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
  // opens it next — the toolbar button or a fresh upload — starts clean: the
  // rows the core drops stay out of the panel until it has dropped them.
  const transfersDismissed = useRef(false);
  const [dismissedTransfers, setDismissedTransfers] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const openTransfers = useCallback(() => {
    if (transfersDismissed.current) {
      transfersDismissed.current = false;
      setDismissedTransfers(
        new Set(
          snapshot.transfers
            .filter((transfer) => transfer.status !== "in_progress")
            .map((transfer) => transfer.id)
        )
      );
      void call("drive.dismissTransfers", {}).catch(() => undefined);
    }
    setTransfersOpen(true);
  }, [call, snapshot.transfers]);
  const shownTransfers = useMemo(
    () => snapshot.transfers.filter((transfer) => !dismissedTransfers.has(transfer.id)),
    [dismissedTransfers, snapshot.transfers]
  );
  const dismissTransfers = useCallback(() => {
    transfersDismissed.current = true;
    setTransfersOpen(false);
  }, []);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  // File previews are tabs of the shell's one right sidebar, not a second
  // sidebar: registering this host is what points that sidebar at Drive.
  const { closeDrivePreview, openDrivePreview } = useChatSidebar();
  useRegisterChatSidebarHost(driveSidebarHost);

  const selectedSpace = snapshot.spaces.find(
    (space) => space.id === snapshot.selectedSpaceId
  );
  const selectedSpaceWritable = selectedSpace?.writable !== false;
  // The core lists the picked origin device's copies already.
  const spaceFiles = useMemo(
    () => snapshot.files.filter((file) => file.spaceId === snapshot.selectedSpaceId),
    [snapshot.files, snapshot.selectedSpaceId]
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
      void downloadDriveFile(file, transferDeps);
    },
    [transferDeps]
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
          (file.sizeBytes <= MAX_ATTACHMENT_BYTES
            ? await ensureDriveFileBlob(store, call, file).catch(() => undefined)
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
        await attempt.run(async (signal) => {
          let target = registry.getHomeConversationTarget();
          if (!target) {
            const resolution = await resolveWorkspaceChat({
              core: registry.core,
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
    [call, clearSelection, locale, messages, navigate, registry, store]
  );

  const onFileMenuAction = useCallback(
    (action: DriveFileMenuAction, file: DriveFile) => {
      if (action === "ask-comma-agent") {
        void askCommaAgent([file]);
        return;
      }
      if (action === "download") {
        runDownload(file);
        return;
      }
      if (action === "keep-offline") {
        if (file.system) return;
        const keepOffline = !(file.keepOffline ?? false);
        void call("drive.keepOffline", { files: [file.id], keepOffline })
          .then(() => {
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
      // Delete leaves the space on every device, so it is confirmed first;
      // the removal itself happens in `confirmDelete`.
      if (!driveFileWritable(file, store.getSnapshot().spaces)) return;
      setDeleteTarget([file]);
    },
    [askCommaAgent, call, messages, nodeRejected, runDownload, store]
  );

  const confirmDelete = useCallback(async () => {
    const files = deleteTarget;
    if (!files || files.length === 0) return;
    if (files.some((file) => !driveFileWritable(file, store.getSnapshot().spaces)))
      return;
    try {
      await call("drive.delete", { files: files.map((file) => file.id) });
    } catch (error) {
      setDeleteTarget(undefined);
      // The Router changed a System Files entry since it was shown: the latest shows, and the user decides again.
      toast.error(messages.drive_delete_failed_title(), {
        description:
          (error as { code?: unknown } | null)?.code === "changed"
            ? messages.drive_delete_changed_description({ name: files[0]!.name })
            : messages.drive_node_rejected_description(),
        id: "comma-drive-delete",
        testId: "comma-drive-delete",
      });
      return;
    }
    for (const file of files) closePreviewTab(file.id);
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
  }, [call, closePreviewTab, deleteTarget, messages, store]);

  const onSpaceMenuAction = useCallback(
    (action: DriveSpaceMenuAction, space: DriveSpace) => {
      if (action === "rename") {
        setFolderDialog({ space });
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

  const syncSpace = useCallback(
    (space: DriveSpace, synced: boolean) =>
      call("drive.setSpaceSynced", { space: space.id, synced }),
    [call]
  );

  const onSpaceSyncedChange = useCallback(
    (space: DriveSpace, synced: boolean) => {
      void syncSpace(space, synced)
        .then((counts) => {
          // A space this device publishes reports what it took in; one it
          // replicates is copied by the node as it goes, into its checkout.
          const onDescription = counts
            ? messages.drive_sync_space_on_description({ count: String(counts.adopt) })
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
    },
    [messages, nodeRejected, snapshot.localSyncRoot, syncSpace]
  );

  const onRailAction = useCallback(
    (action: DriveRailMenuAction) => {
      if (action !== "new-folder") {
        folderInputRef.current?.click();
        return;
      }
      // A new space is a folder on this device published to every device: the
      // folder is picked, and its name is the space's.
      void call("drive.addSpace", {})
        .then((added) => {
          if (!added) return;
          store.selectSpace(added.space);
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
    [call, messages, nodeRejected, store]
  );

  const submitFolderName = useCallback(
    (name: string) => {
      const dialog = folderDialog;
      setFolderDialog(undefined);
      if (!dialog) return;
      void call("drive.renameSpace", { space: dialog.space.id, name })
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
    },
    [call, folderDialog, messages, nodeRejected]
  );

  // Turning local sync on starts with choosing what to mirror; turning it
  // off applies at once and keeps each space's own flag for the next time.
  const onLocalSyncEnabledChange = useCallback(
    (enabled: boolean) => {
      if (enabled) {
        setSyncPickerOpen(true);
        return;
      }
      const mirrored = snapshot.spaces.filter((space) => space.synced === true);
      void Promise.all(mirrored.map((space) => syncSpace(space, false))).catch(
        (error: unknown) => nodeRejected(messages.drive_sync_failed_title(), error)
      );
    },
    [messages, nodeRejected, snapshot.spaces, syncSpace]
  );

  const openLocalRoot = useCallback(() => {
    if (!node) return;
    void openDriveLocalRoot()
      .then((opened) => {
        if (!opened) {
          nodeRejected(messages.drive_open_local_failed_title(), "");
        }
      })
      .catch((error: unknown) =>
        nodeRejected(messages.drive_open_local_failed_title(), error)
      );
  }, [messages, nodeRejected, node]);

  const confirmStopSharing = useCallback(() => {
    const target = stopSharingTarget;
    if (!target) return;
    const stop =
      target.kind === "file"
        ? call("drive.delete", { files: [target.fileId] })
        : call("drive.removeSpace", { space: target.spaceId });
    void stop
      .then(() => {
        if (target.kind === "file") {
          closePreviewTab(target.fileId);
          setSelectedFileIds((fileIds) => {
            if (!fileIds.has(target.fileId)) return fileIds;
            const next = new Set(fileIds);
            next.delete(target.fileId);
            return next;
          });
        } else {
          for (const entry of snapshot.files)
            if (entry.spaceId === target.spaceId) closePreviewTab(entry.id);
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
  }, [
    call,
    closePreviewTab,
    messages,
    nodeRejected,
    snapshot.files,
    stopSharingTarget,
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
            files,
            {
              ...(target.length > 0 ? { folderPath: target.join("/") } : {}),
              spaceId: snapshot.selectedSpaceId,
            },
            transferDeps
          );
        }
      });
    },
    [
      folderPath,
      openTransfers,
      snapshot.selectedSpaceId,
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
        sources,
        {
          ...(folderPath.length > 0 ? { folderPath: folderPath.join("/") } : {}),
          spaceId: snapshot.selectedSpaceId,
        },
        transferDeps
      );
    },
    [
      folderPath,
      openTransfers,
      snapshot.selectedSpaceId,
      transferDeps,
      selectedSpaceWritable,
    ]
  );

  const onRetryTransfer = useCallback(
    (transfer: DriveTransfer) => {
      void retryDriveTransfer(transfer, transferDeps);
    },
    [transferDeps]
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
    void downloadDriveFiles(selectedFiles, transferDeps);
    clearSelection();
  }, [clearSelection, openTransfers, selectedFiles, transferDeps]);

  // Mixed selections pin: the action only unpins once every file is already
  // pinned, so the label always names what the press will do.
  const selectionKeptOffline =
    selectedFiles.length > 0 &&
    selectedFiles.every((file) => file.keepOffline ?? false);

  const keepOfflineSelected = useCallback(() => {
    // Nothing of System Files lives on a device to keep.
    if (selectedFiles.length === 0 || selectedFiles.some((file) => file.system)) return;
    const keepOffline = !selectionKeptOffline;
    const changing = selectedFiles.filter(
      (file) => (file.keepOffline ?? false) !== keepOffline
    );
    if (changing.length === 0) return;
    void call("drive.keepOffline", {
      files: changing.map((file) => file.id),
      keepOffline,
    })
      .then(() => {
        toast(
          keepOffline
            ? messages.drive_keep_offline_on_title()
            : messages.drive_keep_offline_off_title(),
          {
            description: keepOffline
              ? messages.drive_keep_offline_on_many({ count: String(changing.length) })
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
  }, [call, messages, nodeRejected, selectedFiles, selectionKeptOffline]);

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
      enabled: node,
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
            device={node}
            devices={snapshot.devices}
            localSyncEnabled={snapshot.localSyncEnabled}
            localSyncRoot={snapshot.localSyncRoot}
            onLocalSyncEnabledChange={onLocalSyncEnabledChange}
            onOpenLocalRoot={openLocalRoot}
            onOpenSyncHistory={() => setSyncHistoryOpen(true)}
            onSelectDevice={(deviceId) =>
              void call("drive.setView", { originDeviceId: deviceId }).catch(
                () => undefined
              )
            }
            onSelectVersionPolicy={(policy) =>
              void call("drive.setView", { versionPolicy: policy }).catch(
                () => undefined
              )
            }
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
              onNeedThumbnail={(file) =>
                void ensureDriveFileThumbnail(store, call, file).catch(() => {})
              }
              onRetryNode={() =>
                void call("drive.restart", {}).catch((error: unknown) =>
                  nodeRejected(messages.drive_node_error_title(), error)
                )
              }
              onUploadFiles={openFilePicker}
              node={snapshot.node}
              selectedFileIds={selectedFileIds}
              selecting={selectedFiles.length > 0}
              pinnable={node && selectedSpace?.remote !== true}
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
          mode={{ currentName: folderDialog.space.name, kind: "rename" }}
          onClose={() => setFolderDialog(undefined)}
          onSubmit={submitFolderName}
          synced={folderDialog.space.synced ?? false}
        />
      ) : null}
      {syncHistoryOpen ? (
        <DriveSyncHistoryDialog
          entries={snapshot.syncHistory}
          onClose={() => setSyncHistoryOpen(false)}
          onRetryFailures={() =>
            void call("drive.retrySync", {}).catch((error: unknown) =>
              nodeRejected(messages.drive_sync_failed_title(), error)
            )
          }
        />
      ) : null}
      {syncPickerOpen ? (
        <DriveSyncFoldersDialog
          onClose={() => setSyncPickerOpen(false)}
          onConfirm={async (spaceIds) => {
            const selected = snapshot.spaces.filter((space) => spaceIds.has(space.id));
            if (selected.length === 0) return;
            try {
              const changes = snapshot.spaces.filter(
                (space) => Boolean(space.synced) !== spaceIds.has(space.id)
              );
              const results = await Promise.allSettled(
                changes.map((space) => syncSpace(space, spaceIds.has(space.id)))
              );
              const failed = results.find((result) => result.status === "rejected");
              if (failed?.status === "rejected") throw failed.reason;
              setSyncPickerOpen(false);
              toast.success(messages.drive_sync_started_title(), {
                description: messages.drive_sync_started_description({
                  count: String(selected.length),
                  path: selected
                    .map(
                      (space) =>
                        space.originPath ||
                        `${driveSpacesRoot(snapshot.localSyncRoot)}/${space.id}`
                    )
                    .join(", "),
                }),
                id: "comma-drive-sync-started",
                testId: "comma-drive-sync-started",
              });
            } catch (error) {
              nodeRejected(messages.drive_sync_failed_title(), error);
            }
          }}
          sizeOf={(spaceId) =>
            snapshot.files.reduce(
              (total, file) =>
                file.spaceId === spaceId ? total + file.sizeBytes : total,
              0
            )
          }
          spaces={snapshot.spaces.filter((space) => !space.remote)}
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
        transfers={shownTransfers}
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
