// A Task file row's context menu: add the file to this chat's message by reference, copy the file or its name, open
// it in an app or reveal it in Finder (the macOS desktop), or download it (elsewhere). One menu serves the whole list:
// it holds the file it was opened on.
//
// Bounds: the apps that open a file are listed only while the Open in submenu shows, once per opening.
/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { useCall, type TaskFile } from "@comma/core-client";
import type { ChatPanelFileApplication } from "@comma/ui/components/chat-panel";
import { ChevronRightSmallIcon, FileTextIcon } from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  SubmenuTrigger,
  menuCompactClasses,
  useTextEditContextMenuState,
} from "@comma/ui/components/menu";
import { toast } from "@comma/ui/components/toast";
import { motionDuration } from "@comma/ui/tokens";
import { useEffect, useMemo, useRef, useState, type MouseEvent } from "react";
import { nativePlatformClipboard } from "../../../nativePlatformActions";
import { canCopyFile, copySavedFile } from "../../../runtime-files/fileClipboard";
import { downloadFile } from "../../../runtime-files/fileDownloads";
import { createFileOpenInAction } from "../../../runtime-files/fileOpenActions";
import {
  conversationFileLink,
  readConversationFileParts,
  resolveConversationFile,
  saveConversationFile,
} from "../../../runtime-files/fileSources";
import { useOptionalChatRegistry } from "../ChatProvider";
import { taskFileSource } from "./TaskFilePreviewCard";

const isAbort = (error: unknown) =>
  error instanceof DOMException && error.name === "AbortError";
/** One toast for any of the menu's failures: a second replaces the first. */
const failed = (title: string, description?: string) => () =>
  toast.error(title, {
    ...(description ? { description } : {}),
    id: "task-file-action-failed",
    testId: "task-file-action-failed",
  });

export function useTaskFileMenu({
  groupId,
  onAttachFile,
}: {
  groupId: string;
  /** Adds the file to this chat's message by reference; absent where there is no message to add it to. */
  onAttachFile?: ((file: TaskFile) => unknown) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const registry = useOptionalChatRegistry();
  const beginAttempt = registry?.beginAttempt;
  const state = useTextEditContextMenuState({ isEnabled: true });
  const triggerRef = useRef<Element | null>(null);
  const [file, setFile] = useState<TaskFile>();
  // An action outlives its menu, not the panel.
  const lifetime = useRef<AbortController | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    return () => controller.abort();
  }, []);

  const source = useMemo(
    () => (file ? taskFileSource(groupId, file) : undefined),
    [file, groupId]
  );
  // Opening in an app and revealing are the macOS desktop's; elsewhere the menu downloads the file.
  const openIn = useMemo(
    () =>
      source && beginAttempt
        ? createFileOpenInAction({ call, source, locale, beginAttempt })
        : undefined,
    [beginAttempt, call, locale, source]
  );

  const open = (event: MouseEvent<HTMLElement>, target: TaskFile) => {
    event.preventDefault();
    triggerRef.current = event.currentTarget;
    setFile(target);
    state.openAtPointer(event.currentTarget, event.clientX, event.clientY);
  };

  // A submenu's item closes only its submenu: each action closes the whole menu itself.
  const close = () => state.handleOpenChange(false);
  const act = (run: (signal: AbortSignal) => Promise<unknown>, failure: () => void) => {
    close();
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted) return;
    void run(signal).catch((error: unknown) => {
      if (!signal.aborted && !isAbort(error)) failure();
    });
  };
  const menu =
    file && source ? (
      <MenuPopover
        crossOffset={state.pointerOffsets?.crossOffset ?? 0}
        isOpen={state.isOpen}
        offset={state.pointerOffsets?.offset ?? 0}
        onOpenChange={state.handleOpenChange}
        placement="right top"
        triggerRef={triggerRef}
      >
        <Menu
          aria-label={messages.task_panel_file_menu({ name: file.file_name })}
          autoFocus="first"
          className={menuCompactClasses}
          data-testid="task-file-menu"
          onClose={() => state.handleOpenChange(false)}
        >
          <MenuItem
            id="add-to-context"
            isDisabled={!onAttachFile}
            onAction={() =>
              act(
                async () => onAttachFile?.(file),
                failed(messages.task_panel_file_attach_failed())
              )
            }
          >
            {messages.image_context_add()}
          </MenuItem>
          {canCopyFile() ? (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
              <MenuItem
                id="copy"
                shortcut={<ChevronRightSmallIcon className="size-4" />}
              >
                {messages.common_copy()}
              </MenuItem>
              <MenuPopover offset={0} placement="right top">
                <Menu
                  aria-label={messages.common_copy()}
                  className={menuCompactClasses}
                  data-testid="task-file-menu-copy"
                >
                  <MenuItem
                    id="copy-file"
                    onAction={() =>
                      act(
                        (signal) =>
                          copySavedFile(
                            saveConversationFile(call, source),
                            locale,
                            signal,
                            {
                              kind: "file",
                            }
                          ),
                        failed(messages.task_panel_file_copy_failed())
                      )
                    }
                  >
                    {messages.session_action_copy()}
                  </MenuItem>
                  <CopyNameItem name={file.file_name} onCopy={close} />
                </Menu>
              </MenuPopover>
            </SubmenuTrigger>
          ) : (
            <CopyNameItem name={file.file_name} onCopy={close} />
          )}
          <MenuSeparator />
          {openIn ? (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
              <MenuItem
                id="open-in"
                shortcut={<ChevronRightSmallIcon className="size-4" />}
              >
                {messages.ui_file_open_in()}
              </MenuItem>
              <MenuPopover offset={0} placement="right top">
                <OpenInApplications
                  listApplications={openIn.listApplications}
                  onOpen={(application) =>
                    act(
                      (signal) => openIn.openApplication(application.id, signal),
                      failed(messages.file_download_open_failed_title())
                    )
                  }
                />
              </MenuPopover>
            </SubmenuTrigger>
          ) : null}
          {openIn?.reveal ? (
            <MenuItem
              id="reveal"
              onAction={() =>
                act(
                  (signal) => openIn.reveal!.run(signal),
                  failed(
                    messages.file_download_failed_title(),
                    messages.file_download_failed_description({
                      fileName: file.file_name,
                    })
                  )
                )
              }
            >
              {openIn.reveal.label}
            </MenuItem>
          ) : (
            <MenuItem
              id="download"
              onAction={() =>
                // The download reports its own outcome.
                act(
                  () =>
                    downloadFile(
                      {
                        fileName: file.file_name,
                        resolve: (signal) =>
                          resolveConversationFile(call, source, signal),
                        save: saveConversationFile(call, source),
                        link: conversationFileLink(call, source),
                        parts: readConversationFileParts(call, source),
                      },
                      { locale }
                    ),
                  () => undefined
                )
              }
            >
              {messages.drive_file_menu_download()}
            </MenuItem>
          )}
        </Menu>
      </MenuPopover>
    ) : null;

  // The file the menu is open on, by its place in the Task: a read of the list while it is open gives new objects.
  const openOn = state.isOpen && file ? `${file.message_id}:${file.index}` : undefined;
  return { menu, open, openOn };
}

function CopyNameItem({ name, onCopy }: { name: string; onCopy: () => void }) {
  const messages = useCommaMessages();
  return (
    <MenuItem
      id="copy-name"
      onAction={() => {
        onCopy();
        void nativePlatformClipboard.writeText(name).then(
          () =>
            toast.success(messages.task_panel_file_name_copied(), {
              description: name,
              id: "task-file-name-copy",
              testId: "task-file-name-copy",
            }),
          failed(messages.task_panel_file_name_copy_failed())
        );
      }}
    >
      {messages.task_panel_file_copy_name()}
    </MenuItem>
  );
}

type ApplicationList =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; applications: readonly ChatPanelFileApplication[] };

/** The apps that open the file, listed when the submenu shows. */
function OpenInApplications({
  listApplications,
  onOpen,
}: {
  listApplications: (
    signal?: AbortSignal
  ) => Promise<readonly ChatPanelFileApplication[]>;
  onOpen: (application: ChatPanelFileApplication) => void;
}) {
  const messages = useCommaMessages();
  const [list, setList] = useState<ApplicationList>({ status: "loading" });
  useEffect(() => {
    const controller = new AbortController();
    listApplications(controller.signal).then(
      (applications) => {
        if (!controller.signal.aborted) setList({ status: "ready", applications });
      },
      () => {
        if (!controller.signal.aborted) setList({ status: "error" });
      }
    );
    return () => controller.abort();
  }, [listApplications]);
  return (
    <Menu
      aria-label={messages.ui_file_open_in()}
      className={menuCompactClasses}
      data-testid="task-file-menu-open-in"
    >
      {list.status === "loading" ? (
        <MenuItem id="loading" isDisabled>
          {messages.ui_file_open_in_loading()}
        </MenuItem>
      ) : list.status === "error" ? (
        <MenuItem id="error" isDisabled>
          {messages.ui_file_open_in_failed()}
        </MenuItem>
      ) : list.applications.length === 0 ? (
        <MenuItem id="empty" isDisabled>
          {messages.ui_file_open_in_unavailable()}
        </MenuItem>
      ) : (
        list.applications.map((application) => (
          <MenuItem
            icon={
              application.iconDataUrl ? (
                <img
                  alt=""
                  className="chat-panel-file-app-icon"
                  src={application.iconDataUrl}
                />
              ) : (
                <FileTextIcon />
              )
            }
            id={application.id}
            key={application.id}
            onAction={() => onOpen(application)}
            textValue={application.name}
          >
            {application.name}
          </MenuItem>
        ))
      )}
    </Menu>
  );
}
/* oxlint-enable jsx-a11y/no-autofocus */
