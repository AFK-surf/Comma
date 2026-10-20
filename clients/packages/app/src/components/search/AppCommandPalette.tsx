import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  CommandPalette,
  CommandPaletteHighlight,
  type CommandPaletteActiveChangeSource,
  type CommandPaletteGroup,
  type CommandPaletteItem,
} from "@comma/ui/components/command-palette";
import { appKeybindingKeycaps } from "@comma/ui/components/settings-shortcut";
import { taskStatusIcon } from "@comma/ui/components/task-workspace";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useCall, type TaskSearchResult } from "@comma/core-client";
import { useOptionalAppShortcutBinding } from "../shortcuts/commaAppShortcuts";
import { useWorkspaceTasks, type TaskViewModel } from "../tasks/useWorkspaceTasks";
import { normalizeUnixTimestampMs } from "./normalizeUnixTimestampMs";
import { TaskConversationPreview } from "./TaskConversationPreview";
import {
  firstHighlightExcerpt,
  findTextHighlights,
  type TextHighlight,
} from "./searchText";

const taskHistoryLimit = 20;
// The server keeps two-codepoint queries on its bounded short-gram index; this
// preserves useful searches such as "AI" and common two-character CJK terms.
const taskSearchMinQueryCodepoints = 2;
const taskSearchMaxQueryCodepoints = 128;

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
  status?: string;
  title: string;
  updatedAt?: number;
  workspaceId: string;
};

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
}: {
  onActionClose: () => void;
  onOpenChange: (open: boolean) => void;
  open: boolean;
}) {
  const locale = useCommaLocale();
  const m = useCommaMessages();
  const navigate = useNavigate();
  const searchShortcut = useOptionalAppShortcutBinding("go-search");
  const searchShortcutKeycaps = appKeybindingKeycaps(searchShortcut);
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

  const historyItems = recentTasks.map<CommandPaletteItem<string>>((task) => {
    const value = `task:${task.groupId}:${task.conversationId}`;
    taskTargets.set(value, taskTarget(task));
    return {
      icon: taskStatusIcon(task.statusBucket),
      meta: taskUpdatedAt(task.updatedAt, locale),
      title: task.title,
      value,
    };
  });

  const searchItems = taskSearch.results.map<CommandPaletteItem<string>>((result) => {
    const value = `task:${taskSearch.scope?.groupId ?? "unknown"}:${result.conversation_id}`;
    const knownTask = tasksByConversation.get(result.conversation_id);
    const scope = taskSearch.scope;
    const updatedAt = result.updated_at ?? knownTask?.updatedAt;
    if (scope) {
      taskTargets.set(value, {
        conversationId: result.conversation_id,
        groupId: scope.groupId,
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
    const contentMatch =
      result.content_match ??
      (result.matched_field === "content"
        ? { highlights: result.highlights, snippet: result.snippet }
        : undefined);
    const subtitleExcerpt = contentMatch
      ? firstHighlightExcerpt(contentMatch.snippet, contentMatch.highlights)
      : undefined;
    return {
      icon: taskStatusIcon(knownTask?.statusBucket ?? "in_progress"),
      meta: taskUpdatedAt(updatedAt, locale),
      subtitle: subtitleExcerpt
        ? highlightedText(subtitleExcerpt.text, subtitleExcerpt.highlights)
        : undefined,
      title: highlightedText(result.title, titleHighlights),
      value,
    };
  });

  const groups: CommandPaletteGroup<string>[] = normalizedQuery
    ? [
        {
          heading: m.search_palette_tasks(),
          id: "tasks",
          items: searchItems,
        },
      ]
    : [
        {
          heading: m.search_palette_tasks(),
          id: "tasks",
          items: historyItems,
        },
      ];
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
    const validActiveValue =
      activeValue && selectableValues.includes(activeValue) ? activeValue : undefined;
    const validPreviewValue =
      previewValue && selectableValues.includes(previewValue)
        ? previewValue
        : undefined;
    const nextPreviewValue =
      validPreviewValue ?? validActiveValue ?? selectableValues[0];
    const nextActiveValue = validActiveValue ?? nextPreviewValue;
    if (nextActiveValue !== activeValue) setActiveValue(nextActiveValue);
    if (nextPreviewValue !== previewValue) {
      setPreviewValue(nextPreviewValue);
    }
  }, [activeValue, open, previewValue, selectableValuesKey]);

  const previewTask = previewValue ? taskTargets.get(previewValue) : undefined;
  const previewLabel = previewTask?.title;
  const preview = previewTask ? (
    <TaskConversationPreview searchQuery={normalizedTaskQuery} task={previewTask} />
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
    if (source !== "pointer") setPreviewValue(nextValue);
  };

  const handlePointerIntent = (nextValue: string) => {
    setPreviewValue(nextValue);
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
    });
  };

  const loading = normalizedQuery
    ? taskSearch.loading
    : workspaceTasks.loading && historyItems.length === 0;
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
