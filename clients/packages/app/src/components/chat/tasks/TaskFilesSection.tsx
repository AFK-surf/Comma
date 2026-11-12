// A Task panel's Files: the files and images the Task's Agents attached to its Messages, newest first, as Comma's
// index lists them (`taskFiles.list`). A row opens the file in the sidebar's preview. The list is read when the
// section shows, after each of the Worker's turns, and when the window comes back to the front; a section with no
// files does not show. The heading, with its chevron, shows or hides the list. A long list folds as the Activity
// does: its newest rows, then a row that stands for the rest until pressed. A row's hover card previews the file
// (`TaskFilePreviewCard`), and its context menu acts on it (`useTaskFileMenu`).
//
// Bounds: one read of at most 200 files at a time; what the cards read is kept for the panel's Task
// (`TaskFilePreviewCache`).
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { useCall, type TaskFile, type TaskFilesValue } from "@comma/core-client";
import { ChevronDownSmallIcon, MoreHorizontalIcon } from "@comma/ui/components/icons";
import { FileTypeIcon } from "@comma/ui/components/file-type-icon";
import { HoverCard } from "@comma/ui/components/hover-card";
import { Button } from "react-aria-components";
import { useCallback, useEffect, useId, useState } from "react";
import { formatAttachmentSize } from "../thread/attachments/attachmentLabels";
import { useReadTickets, useTurnEnds, useWindowReturns } from "./CodingSession";
import { useTaskFileMenu } from "./TaskFileMenu";
import {
  createTaskFilePreviewCache,
  releaseTaskFilePreviewCache,
  TaskFilePreviewCard,
} from "./TaskFilePreviewCard";

/** More files than this fold all but the newest five, as the Activity folds a long group. */
const FILE_FOLD = { above: 8, head: 5 };

export function TaskFilesSection({
  conversationId,
  groupId,
  onAttachFile,
  onOpenFile,
  working,
}: {
  conversationId: string;
  groupId: string;
  /** Adds a file to this chat's message by reference. */
  onAttachFile?: ((file: TaskFile) => unknown) | undefined;
  onOpenFile: (file: TaskFile) => void;
  /** The Task's Agent works now: its files are read again once it is done. */
  working?: boolean | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const tickets = useReadTickets();
  const turnEnds = useTurnEnds(working);
  const windowReturns = useWindowReturns();
  const task = `${groupId}:${conversationId}`;
  // What was read, for the Task it was read for: another Task's never shows while this one's is read.
  const [read, setRead] = useState<{ task: string; value: TaskFilesValue }>();
  const [open, setOpen] = useState(true);
  const [all, setAll] = useState(false);
  // The first row the fold row gave way to takes its focus.
  const [focusIndex, setFocusIndex] = useState<number>();
  useEffect(() => {
    if (focusIndex !== undefined) setFocusIndex(undefined);
  }, [focusIndex]);
  const listId = useId();
  const [previews] = useState(createTaskFilePreviewCache);
  useEffect(() => () => releaseTaskFilePreviewCache(previews), [previews]);
  const fileMenu = useTaskFileMenu({ groupId, onAttachFile });

  const load = useCallback(() => {
    const ticket = tickets.take();
    call("taskFiles.list", { group: groupId, conversation: conversationId }).then(
      (value) => {
        if (!tickets.current(ticket)) return;
        // A failed read keeps the files already shown.
        setRead((current) =>
          value.status === "error" &&
          current?.task === task &&
          current.value.status === "ready"
            ? current
            : { task, value }
        );
      },
      () => undefined
    );
  }, [call, conversationId, groupId, task, tickets]);
  useEffect(load, [load, turnEnds, windowReturns]);

  const value = read?.task === task ? read.value : undefined;
  if (!value || (value.status === "ready" && value.files.length === 0)) return null;

  const { files } = value;
  const folded = !all && files.length > FILE_FOLD.above;
  const shown = folded ? files.slice(0, FILE_FOLD.head) : files;
  const hidden = files.length - shown.length;
  const listed = value.status === "ready";
  return (
    <section className="comma-task-panel-section" data-testid="task-panel-files">
      <h2 className="comma-task-panel-heading">
        {listed ? (
          <Button
            {...(open ? { "aria-controls": listId } : {})}
            aria-expanded={open}
            className="comma-task-panel-files-toggle"
            data-testid="task-panel-files-toggle"
            onPress={() => setOpen((current) => !current)}
          >
            {messages.task_panel_files()}
            <ChevronDownSmallIcon aria-hidden />
          </Button>
        ) : (
          messages.task_panel_files()
        )}
      </h2>
      {listed ? (
        open ? (
          <ul className="flex flex-col gap-xs" id={listId}>
            {shown.map((file, index) => {
              const size = formatAttachmentSize(file.size, locale);
              return (
                <li key={`${file.message_id}:${file.index}`}>
                  <HoverCard
                    content={
                      <TaskFilePreviewCard
                        file={file}
                        groupId={groupId}
                        cache={previews}
                      />
                    }
                    // The panel is the window's trailing column: the card opens over the chat beside it.
                    placement="start top"
                    pointerOnly
                  >
                    <Button
                      aria-label={messages.task_panel_file_open({
                        name: file.file_name,
                      })}
                      className="comma-task-panel-pill max-w-full min-w-0"
                      data-interactive="true"
                      data-menu-open={
                        fileMenu.openOn === `${file.message_id}:${file.index}`
                          ? "true"
                          : undefined
                      }
                      data-testid="task-panel-file"
                      onContextMenu={(event) => fileMenu.open(event, file)}
                      onPress={() => onOpenFile(file)}
                      ref={index === focusIndex ? focusOnMount : undefined}
                    >
                      <FileTypeIcon
                        className="size-5"
                        fileName={file.file_name}
                        mimeType={file.mime_type ?? undefined}
                      />
                      <span className="truncate" title={file.file_name}>
                        {file.file_name}
                      </span>
                      {size ? (
                        <span className="shrink-0 font-normal text-quaternary">
                          {size}
                        </span>
                      ) : null}
                    </Button>
                  </HoverCard>
                </li>
              );
            })}
            {hidden > 0 ? (
              <li data-fold="true">
                <Button
                  className="comma-task-panel-pill max-w-full min-w-0"
                  data-interactive="true"
                  data-testid="task-panel-files-more"
                  onPress={() => {
                    setAll(true);
                    setFocusIndex(shown.length);
                  }}
                >
                  <span aria-hidden="true" className="comma-icon-slot size-5 shrink-0">
                    <MoreHorizontalIcon className="size-5 text-quaternary" />
                  </span>
                  <span className="truncate font-normal text-tertiary">
                    {messages.task_panel_files_more({
                      count: hidden,
                      formattedCount: formatNumber(hidden, locale),
                    })}
                  </span>
                </Button>
              </li>
            ) : null}
          </ul>
        ) : null
      ) : (
        <p
          className="comma-task-panel-muted"
          data-testid="task-panel-files-unavailable"
        >
          {value.status === "indexing"
            ? messages.task_panel_files_indexing()
            : messages.task_panel_files_failed()}
        </p>
      )}
      {fileMenu.menu}
    </section>
  );
}

function focusOnMount(node: HTMLElement | null) {
  node?.focus();
}
