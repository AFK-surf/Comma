import { formatDate, messages, type CommaLocale } from "@comma/i18n";
import type { ApplicationMenuCommand } from "@comma/native-bridge";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  CommandPalette,
  CommandPaletteHighlight,
  CommandPaletteKeycaps,
  type CommandPaletteActiveChangeSource,
  type CommandPaletteGroup,
  type CommandPaletteItem,
} from "@comma/ui/components/command-palette";
import { appKeybindingKeycaps } from "@comma/ui/components/settings-shortcut";
import { taskStatusIcon } from "@comma/ui/components/task-workspace";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useCall, type TaskFile, type TaskSearchResult } from "@comma/core-client";
import { FileIcon, ImageIcon } from "@comma/ui/components/icons";
import type { ChatSidebarActions } from "../chat-sidebar/ChatSidebarContext";
import {
  runApplicationMenuCommand,
  useEnabledApplicationMenuCommands,
} from "../application-menu/useApplicationMenu";
import { AppIcon, type AppIconName } from "../icons";
import { appShortcutTitle, useAppShortcutCopy } from "../shortcuts/appShortcutCopy";
import type { AppShortcutId } from "../shortcuts/appShortcutRegistry";
import {
  useOptionalAppShortcutBinding,
  useOptionalAppShortcutBindings,
} from "../shortcuts/commaAppShortcuts";
import { useWorkspaceTasks, type TaskViewModel } from "../tasks/useWorkspaceTasks";
import { useNewTaskDialog } from "../tasks/station/NewTaskDialogContext";
import { normalizeUnixTimestampMs } from "./normalizeUnixTimestampMs";
import { TaskConversationPreview } from "./TaskConversationPreview";
import {
  firstHighlightExcerpt,
  findTextHighlights,
  titleMatches,
  waitsForTasks,
  type TextHighlight,
} from "./searchText";

const taskHistoryLimit = 20;
// The server keeps two-codepoint queries on its bounded short-gram index; this
// preserves useful searches such as "AI" and common two-character CJK terms.
const taskSearchMinQueryCodepoints = 2;
const taskSearchMaxQueryCodepoints = 128;

// The app commands the palette offers beside Tasks, in the order it lists them.
// Search is the palette itself; history steps are left to the window bar.
const paletteActions = [
  { icon: "home", id: "go-comma-assistant" },
  { icon: "inbox", id: "go-inbox" },
  { icon: "tasks", id: "go-tasks" },
  { icon: "drive", id: "go-drive" },
  { icon: "plugins", id: "go-plugins" },
  { icon: "plus", id: "new-task" },
  { icon: "settings", id: "go-settings" },
  { icon: "layout-left", id: "toggle-left-sidebar" },
  { icon: "layout-right", id: "toggle-right-sidebar" },
] as const satisfies readonly { icon: AppIconName; id: AppShortcutId }[];

type Message = (inputs?: undefined, options?: { locale?: CommaLocale }) => string;

// The application menu's commands the palette offers after those, in this
// order, each while a mounted surface has it enabled (the desktop app's menu:
// none elsewhere). Those the shortcuts above already offer are not repeated.
const menuPaletteActions = [
  { icon: "reload", id: "check-updates", title: messages.search_palette_check_updates },
  { icon: "mic", id: "record-start", title: messages.search_palette_record_start },
  { icon: "mic", id: "record-pause", title: messages.search_palette_record_pause },
  { icon: "mic", id: "record-resume", title: messages.search_palette_record_resume },
  { icon: "mic", id: "record-stop", title: messages.search_palette_record_stop },
  { icon: "plus", id: "drive-upload", title: messages.search_palette_drive_upload },
  {
    icon: "plus",
    id: "drive-upload-folder",
    title: messages.search_palette_drive_upload_folder,
  },
  {
    icon: "drive",
    id: "drive-add-folder",
    title: messages.search_palette_drive_add_folder,
  },
  {
    icon: "drive",
    id: "drive-download",
    title: messages.search_palette_drive_download,
  },
  {
    icon: "plus",
    id: "browser-new-tab",
    title: messages.search_palette_browser_new_tab,
  },
  {
    icon: "window-close",
    id: "browser-close-tab",
    title: messages.search_palette_browser_close_tab,
  },
  { icon: "sparkles", id: "go-routines", title: messages.search_palette_go_routines },
  { icon: "settings", id: "go-shortcuts", title: messages.search_palette_go_shortcuts },
  {
    icon: "mic",
    id: "go-recording-settings",
    title: messages.search_palette_recording_settings,
  },
] as const satisfies readonly {
  icon: AppIconName;
  id: ApplicationMenuCommand;
  title: Message;
}[];

const actionValuePrefix = "action:";
const menuValuePrefix = "menu:";
const taskValuePrefix = "task:";
const fileValuePrefix = "file:";

function isTaskValue(value: string) {
  return value.startsWith(taskValuePrefix);
}

type SearchScope = {
  groupId: string;
  workspaceId: string;
};

type TaskSearchState = {
  error: boolean;
  loading: boolean;
  results: TaskSearchResult[];
  scope?: SearchScope | undefined;
  validationError: boolean;
};

type PaletteTask = {
  conversationId: string;
  groupId: string;
  /** The Message a search hit matched: the preview and the opened Task show it. */
  messageId?: string | undefined;
  status?: string;
  title: string;
  updatedAt?: number;
  workspaceId: string;
};

/** A file a Task's Agents attached, found by its name, and where its Task opens. */
type PaletteFile = { file: TaskFile; scope: SearchScope };

type TaskFileSearchState = { files: TaskFile[]; scope?: SearchScope | undefined };

const idleTaskSearch: TaskSearchState = {
  error: false,
  loading: false,
  results: [],
  validationError: false,
};

function boundedTaskQuery(query: string) {
  return Array.from(query.trim().normalize("NFKC"))
    .slice(0, taskSearchMaxQueryCodepoints)
    .join("");
}

/** Each query is one core search, cancelled when the query changes; the core asks once it has stayed typed 180 ms. */
function useTaskSearch(
  open: boolean,
  query: string,
  preferredScope: SearchScope | undefined,
  preferredWorkspaceId: string | undefined
): TaskSearchState {
  const call = useCall();
  const normalizedQuery = boundedTaskQuery(query);
  const eligible =
    open && Array.from(normalizedQuery).length >= taskSearchMinQueryCodepoints;
  const requestKey = `${preferredScope?.groupId ?? ""}\u0000${preferredWorkspaceId ?? ""}\u0000${normalizedQuery}`;
  const [answer, setAnswer] = useState<{ key: string; state: TaskSearchState }>();
  useEffect(() => {
    if (!eligible) return;
    const controller = new AbortController();
    call(
      "search.tasks",
      {
        query: normalizedQuery,
        group: preferredScope?.groupId ?? "",
        prefer: preferredScope?.workspaceId ?? preferredWorkspaceId ?? "",
      },
      controller.signal
    ).then(
      (value) => {
        if (controller.signal.aborted) return;
        setAnswer({
          key: requestKey,
          state: {
            error: value.status === "error",
            loading: false,
            results: value.results,
            scope: value.scope ?? undefined,
            validationError: value.status === "invalid",
          },
        });
      },
      () => {
        if (!controller.signal.aborted)
          setAnswer({ key: requestKey, state: { ...idleTaskSearch, error: true } });
      }
    );
    return () => controller.abort();
  }, [
    call,
    eligible,
    normalizedQuery,
    preferredScope,
    preferredWorkspaceId,
    requestKey,
  ]);
  if (!eligible) return idleTaskSearch;
  if (answer?.key !== requestKey) return { ...idleTaskSearch, loading: true };
  return answer.state;
}

/** File names that contain the query, as `useTaskSearch` asks: one core search per query, cancelled when it changes. */
function useTaskFileSearch(
  open: boolean,
  query: string,
  preferredScope: SearchScope | undefined,
  preferredWorkspaceId: string | undefined
): TaskFileSearchState {
  const call = useCall();
  const normalizedQuery = boundedTaskQuery(query);
  const eligible =
    open && Array.from(normalizedQuery).length >= taskSearchMinQueryCodepoints;
  const requestKey = `${preferredScope?.groupId ?? ""}\u0000${preferredWorkspaceId ?? ""}\u0000${normalizedQuery}`;
  const [answer, setAnswer] = useState<{ key: string; state: TaskFileSearchState }>();
  useEffect(() => {
    if (!eligible) return;
    const controller = new AbortController();
    call(
      "search.taskFiles",
      {
        query: normalizedQuery,
        group: preferredScope?.groupId ?? "",
        prefer: preferredScope?.workspaceId ?? preferredWorkspaceId ?? "",
      },
      controller.signal
    ).then(
      (value) => {
        if (!controller.signal.aborted)
          setAnswer({
            key: requestKey,
            state: { files: value.files, scope: value.scope ?? undefined },
          });
      },
      () => undefined
    );
    return () => controller.abort();
  }, [
    call,
    eligible,
    normalizedQuery,
    preferredScope,
    preferredWorkspaceId,
    requestKey,
  ]);
  return eligible && answer?.key === requestKey ? answer.state : { files: [] };
}

function highlightedText(
  text: string,
  highlights: readonly TextHighlight[]
): ReactNode {
  if (highlights.length === 0) return text;
  const parts: ReactNode[] = [];
  let cursor = 0;
  highlights.forEach((highlight, index) => {
    if (highlight.start > cursor) parts.push(text.slice(cursor, highlight.start));
    parts.push(
      <CommandPaletteHighlight key={`${highlight.start}:${highlight.end}:${index}`}>
        {text.slice(highlight.start, highlight.end)}
      </CommandPaletteHighlight>
    );
    cursor = highlight.end;
  });
  if (cursor < text.length) parts.push(text.slice(cursor));
  return parts;
}

function taskUpdatedAt(
  updatedAt: number | undefined,
  locale: ReturnType<typeof useCommaLocale>
) {
  if (!updatedAt || !Number.isFinite(updatedAt)) return undefined;
  const milliseconds = normalizeUnixTimestampMs(updatedAt);
  if (milliseconds === undefined) return undefined;
  return formatDate(milliseconds, locale, { day: "numeric", month: "short" });
}

function taskTarget(task: TaskViewModel): PaletteTask {
  return {
    conversationId: task.conversationId,
    groupId: task.groupId,
    status: task.activityStatus,
    title: task.title,
    updatedAt: task.updatedAt,
    workspaceId: task.workspaceId,
  };
}

export function AppCommandPalette({
  onActionClose,
  onOpenChange,
  open,
  openFilePreview,
  runShortcut,
}: {
  onActionClose: () => void;
  onOpenChange: (open: boolean) => void;
  open: boolean;
  /** Opens a found file in its Task's sidebar preview; without it a file opens its Task alone. */
  openFilePreview?: ChatSidebarActions["openFilePreview"] | undefined;
  /** Runs an app command; without it the palette offers only Tasks. */
  runShortcut?: (id: AppShortcutId) => void;
}) {
  const locale = useCommaLocale();
  const m = useCommaMessages();
  const navigate = useNavigate();
  const searchShortcut = useOptionalAppShortcutBinding("go-search");
  const searchShortcutKeycaps = appKeybindingKeycaps(searchShortcut);
  const shortcutBindings = useOptionalAppShortcutBindings();
  const shortcutCopy = useAppShortcutCopy();
  const newTask = useNewTaskDialog();
  const enabledMenuCommands = useEnabledApplicationMenuCommands();
  const [query, setQuery] = useState("");
  const [activeValue, setActiveValue] = useState<string>();
  const [previewValue, setPreviewValue] = useState<string>();
  const workspaceTasks = useWorkspaceTasks({ enabled: open });
  const preferredScope = useMemo<SearchScope | undefined>(
    () =>
      workspaceTasks.activeGroupId && workspaceTasks.activeWorkspaceId
        ? {
            groupId: workspaceTasks.activeGroupId,
            workspaceId: workspaceTasks.activeWorkspaceId,
          }
        : undefined,
    [workspaceTasks.activeGroupId, workspaceTasks.activeWorkspaceId]
  );
  const taskSearch = useTaskSearch(
    open,
    query,
    preferredScope,
    workspaceTasks.activeWorkspaceId
  );
  const fileSearch = useTaskFileSearch(
    open,
    query,
    preferredScope,
    workspaceTasks.activeWorkspaceId
  );

  const closeAfterAction = () => {
    setQuery("");
    onActionClose();
  };

  useEffect(() => {
    if (!open) {
      setQuery("");
      setActiveValue(undefined);
      setPreviewValue(undefined);
    }
  }, [open]);

  const normalizedQuery = query.trim();
  const normalizedTaskQuery = boundedTaskQuery(query);
  const taskQueryTooShort =
    normalizedQuery.length > 0 &&
    Array.from(normalizedTaskQuery).length < taskSearchMinQueryCodepoints;
  const recentTasks = useMemo(
    () =>
      workspaceTasks.tasks
        .toSorted((left, right) => right.updatedAt - left.updatedAt)
        .slice(0, taskHistoryLimit),
    [workspaceTasks.tasks]
  );
  const tasksByConversation = new Map(
    workspaceTasks.tasks.map((task) => [task.conversationId, task] as const)
  );
  const taskTargets = new Map<string, PaletteTask>();
  const fileTargets = new Map<string, PaletteFile>();

  const actionItems: CommandPaletteItem<string>[] = runShortcut
    ? paletteActions.flatMap(({ icon, id }) => {
        if (id === "new-task" && !newTask.available) return [];
        const title = shortcutCopy[id].title;
        if (
          normalizedQuery &&
          !titleMatches(normalizedQuery, title, appShortcutTitle(id, "en"))
        )
          return [];
        const keycaps = appKeybindingKeycaps(shortcutBindings?.[id] ?? null);
        return [
          {
            icon: <AppIcon name={icon} />,
            ...(keycaps.length > 0
              ? { meta: <CommandPaletteKeycaps keys={keycaps} /> }
              : {}),
            title: highlightedText(title, findTextHighlights(title, normalizedQuery)),
            value: `${actionValuePrefix}${id}`,
          },
        ];
      })
    : [];
  const menuItems = menuPaletteActions.flatMap<CommandPaletteItem<string>>(
    ({ icon, id, title: message }) => {
      if (!enabledMenuCommands.includes(id)) return [];
      const title = message();
      if (
        normalizedQuery &&
        !titleMatches(normalizedQuery, title, message(undefined, { locale: "en" }))
      )
        return [];
      return [
        {
          icon: <AppIcon name={icon} />,
          title: highlightedText(title, findTextHighlights(title, normalizedQuery)),
          value: `${menuValuePrefix}${id}`,
        },
      ];
    }
  );
  const actionGroup: CommandPaletteGroup<string> = {
    heading: m.search_palette_actions(),
    id: "actions",
    items: [...actionItems, ...menuItems],
  };

  const historyItems = recentTasks.map<CommandPaletteItem<string>>((task) => {
    const value = `${taskValuePrefix}${task.groupId}:${task.conversationId}`;
    taskTargets.set(value, taskTarget(task));
    return {
      icon: taskStatusIcon(task.statusBucket),
      meta: taskUpdatedAt(task.updatedAt, locale),
      title: task.title,
      value,
    };
  });

  const searchItems = taskSearch.results.map<CommandPaletteItem<string>>((result) => {
    const value = `${taskValuePrefix}${taskSearch.scope?.groupId ?? "unknown"}:${result.conversation_id}`;
    const knownTask = tasksByConversation.get(result.conversation_id);
    const scope = taskSearch.scope;
    const updatedAt = result.updated_at ?? knownTask?.updatedAt;
    const contentMatch =
      result.content_match ??
      (result.matched_field === "content"
        ? {
            highlights: result.highlights,
            message_id: result.message_id,
            snippet: result.snippet,
          }
        : undefined);
    if (scope) {
      taskTargets.set(value, {
        conversationId: result.conversation_id,
        groupId: scope.groupId,
        ...(contentMatch?.message_id ? { messageId: contentMatch.message_id } : {}),
        ...(knownTask?.activityStatus ? { status: knownTask.activityStatus } : {}),
        title: result.title,
        ...(updatedAt === undefined ? {} : { updatedAt }),
        workspaceId: scope.workspaceId,
      });
    }
    const titleHighlights =
      result.matched_field === "title"
        ? result.highlights
        : findTextHighlights(result.title, normalizedQuery);
    const subtitleExcerpt = contentMatch
      ? firstHighlightExcerpt(contentMatch.snippet, contentMatch.highlights)
      : undefined;
    return {
      // A Task whose status is not known yet shows the glyph still.
      icon: taskStatusIcon(knownTask?.statusBucket ?? "in_progress", {
        spins: knownTask !== undefined,
      }),
      meta: taskUpdatedAt(updatedAt, locale),
      subtitle: subtitleExcerpt
        ? highlightedText(subtitleExcerpt.text, subtitleExcerpt.highlights)
        : undefined,
      title: highlightedText(result.title, titleHighlights),
      value,
    };
  });

  const fileScope = fileSearch.scope;
  const fileItems = fileScope
    ? fileSearch.files.map<CommandPaletteItem<string>>((file) => {
        const value = `${fileValuePrefix}${fileScope.groupId}:${file.conversation_id}:${file.message_id}:${file.index}`;
        fileTargets.set(value, { file, scope: fileScope });
        const Icon = file.type === "image" ? ImageIcon : FileIcon;
        return {
          icon: <Icon />,
          meta: taskUpdatedAt(file.created_at, locale),
          subtitle: file.task_title || undefined,
          title: highlightedText(
            file.file_name,
            findTextHighlights(file.file_name, normalizedQuery)
          ),
          value,
        };
      })
    : [];

  // An empty query keeps the newest Task first; a typed one that names an
  // action is most likely after it, so matching actions lead.
  const groups: CommandPaletteGroup<string>[] = (
    normalizedQuery
      ? [
          actionGroup,
          {
            heading: m.search_palette_tasks(),
            id: "tasks",
            items: searchItems,
          },
          {
            heading: m.search_palette_files(),
            id: "files",
            items: fileItems,
          },
        ]
      : [
          {
            heading: m.search_palette_tasks(),
            id: "tasks",
            items: historyItems,
          },
          actionGroup,
        ]
  ).filter((group) => group.items.length > 0);
  const selectableValuesKey = groups
    .flatMap((group) =>
      group.items.filter((item) => item.disabled !== true).map((item) => item.value)
    )
    .join("\u0000");

  useEffect(() => {
    if (!open) return;
    const selectableValues = selectableValuesKey
      ? selectableValuesKey.split("\u0000")
      : [];
    // Only a Task has a preview: while an action is selected the pane keeps
    // the Task it showed, so the layout does not jump between rows.
    const taskValues = selectableValues.filter(isTaskValue);
    const validActiveValue =
      activeValue && selectableValues.includes(activeValue) ? activeValue : undefined;
    const validPreviewValue =
      previewValue && taskValues.includes(previewValue) ? previewValue : undefined;
    const nextPreviewValue =
      validPreviewValue ??
      (validActiveValue && isTaskValue(validActiveValue)
        ? validActiveValue
        : undefined) ??
      taskValues[0];
    const nextActiveValue = validActiveValue ?? selectableValues[0];
    if (nextActiveValue !== activeValue) setActiveValue(nextActiveValue);
    if (nextPreviewValue !== previewValue) {
      setPreviewValue(nextPreviewValue);
    }
  }, [activeValue, open, previewValue, selectableValuesKey]);

  const previewTask = previewValue ? taskTargets.get(previewValue) : undefined;
  const previewLabel = previewTask?.title;
  const preview = previewTask ? (
    <TaskConversationPreview
      revealMessageId={previewTask.messageId}
      searchQuery={normalizedTaskQuery}
      task={previewTask}
    />
  ) : undefined;

  const handleQueryChange = (nextQuery: string) => {
    if (
      Array.from(nextQuery.trim().normalize("NFKC")).length <=
      taskSearchMaxQueryCodepoints
    ) {
      setActiveValue(undefined);
      setPreviewValue(undefined);
      setQuery(nextQuery);
    }
  };

  const handleActiveValueChange = (
    nextValue: string,
    source: CommandPaletteActiveChangeSource
  ) => {
    setActiveValue(nextValue);
    if (source !== "pointer" && isTaskValue(nextValue)) setPreviewValue(nextValue);
  };

  const handlePointerIntent = (nextValue: string) => {
    if (isTaskValue(nextValue)) setPreviewValue(nextValue);
  };

  const handlePointerIntentCancel = (cancelledValue: string) => {
    setActiveValue((currentValue) =>
      currentValue === cancelledValue ? previewValue : currentValue
    );
  };

  const openTask = (task: PaletteTask) => {
    closeAfterAction();
    void navigate({
      to: "/tasks/$workspaceId/$groupId/$conversationId",
      params: {
        conversationId: task.conversationId,
        groupId: task.groupId,
        workspaceId: task.workspaceId,
      },
      search: task.messageId ? { message: task.messageId, q: normalizedTaskQuery } : {},
    });
  };

  // A file opens its Task, with the file in that Task's sidebar preview.
  const openFile = ({ file, scope }: PaletteFile) => {
    openTask({
      conversationId: file.conversation_id,
      groupId: scope.groupId,
      title: file.task_title,
      workspaceId: scope.workspaceId,
    });
    openFilePreview?.(
      {
        conversationId: file.conversation_id,
        groupId: scope.groupId,
        workspaceId: scope.workspaceId,
      },
      {
        groupId: scope.groupId,
        conversationId: file.conversation_id,
        messageId: file.message_id,
        attachmentIndex: file.index,
        fileName: file.file_name,
        ...(file.mime_type ? { mimeType: file.mime_type } : {}),
        size: file.size,
      }
    );
  };

  const runAction = (id: AppShortcutId) => {
    // A sidebar toggle leaves the user where they were, so focus goes back
    // there; the other actions move them elsewhere.
    if (id === "toggle-left-sidebar" || id === "toggle-right-sidebar") {
      setQuery("");
      onOpenChange(false);
    } else {
      closeAfterAction();
    }
    runShortcut?.(id);
  };
  const runMenuCommand = (id: ApplicationMenuCommand) => {
    // Those that open a page or a tab move the user there; the others leave
    // them where they were, so focus goes back there.
    if (id.startsWith("go-") || id === "browser-new-tab") closeAfterAction();
    else {
      setQuery("");
      onOpenChange(false);
    }
    runApplicationMenuCommand(id);
  };

  // Actions show at once; only a list with nothing else waits for Tasks.
  const loading = waitsForTasks({
    actions: actionGroup.items.length,
    query: normalizedQuery,
    searching: taskSearch.loading,
    loadingHistory: workspaceTasks.loading,
    history: historyItems.length,
  });
  const unavailable = normalizedQuery
    ? taskSearch.error
    : Boolean(workspaceTasks.taskLoadError);
  const invalidQuery = normalizedQuery ? taskSearch.validationError : false;

  return (
    <CommandPalette
      {...(activeValue ? { activeValue } : {})}
      closeLabel={m.search_palette_close()}
      emptyTitle={
        unavailable
          ? m.search_palette_unavailable()
          : invalidQuery
            ? m.search_palette_invalid_query()
            : taskQueryTooShort
              ? m.search_palette_min_query({ count: taskSearchMinQueryCodepoints })
              : m.search_palette_no_results()
      }
      footerHints={[
        { keys: ["↑", "↓"], label: m.search_palette_navigate_hint() },
        { keys: ["↵"], label: m.search_palette_select_hint() },
        ...(searchShortcutKeycaps.length > 0
          ? [
              {
                keys: searchShortcutKeycaps,
                label: m.search_palette_command_hint(),
              },
            ]
          : []),
      ]}
      groups={groups}
      label={m.search_palette_label()}
      listLabel={m.search_palette_results()}
      loading={loading}
      loadingLabel={
        normalizedQuery
          ? m.search_palette_loading()
          : m.search_palette_loading_history()
      }
      onActiveValueChange={handleActiveValueChange}
      onOpenChange={(nextOpen) => {
        if (!nextOpen) setQuery("");
        onOpenChange(nextOpen);
      }}
      onQueryChange={handleQueryChange}
      onPointerIntent={handlePointerIntent}
      onPointerIntentCancel={handlePointerIntentCancel}
      onSelect={(item) => {
        if (item.value.startsWith(actionValuePrefix)) {
          runAction(item.value.slice(actionValuePrefix.length) as AppShortcutId);
          return;
        }
        if (item.value.startsWith(menuValuePrefix)) {
          runMenuCommand(
            item.value.slice(menuValuePrefix.length) as ApplicationMenuCommand
          );
          return;
        }
        const file = fileTargets.get(item.value);
        if (file) {
          openFile(file);
          return;
        }
        const task = taskTargets.get(item.value);
        if (task) openTask(task);
      }}
      open={open}
      placeholder={m.search_palette_placeholder()}
      {...(preview ? { preview } : {})}
      {...(previewLabel ? { previewLabel } : {})}
      query={query}
    />
  );
}
