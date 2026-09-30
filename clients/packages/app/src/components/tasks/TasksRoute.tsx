import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  MacbookIcon,
  type TaskStatusBucket,
  SquareGridCircleIcon,
  TagLabelIcon,
  TaskWorkspace,
  type TaskFilterOption,
  type TaskFilterSection,
  type TaskWorkspaceProps,
  toast,
  type TaskWorkspaceTask,
} from "@comma/ui";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ConversationPreparation } from "../chat/prepareConversations";
import { nativePlatformClipboard } from "../../runtime-chat/nativePlatformActions";
import { useCommaAuth } from "../AuthGate";
import {
  isStaleChatSessionError,
  useChatApi,
  useChatRegistry,
} from "../chat/ChatProvider";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import { useCommaUiThemeName } from "../commaUiTheme";
import { LabelDot } from "./labelColor";
import {
  TASK_ORIGIN_KEYS,
  TaskOriginIcon,
  taskOriginKey,
  taskOriginLabel,
  type TaskOriginKey,
} from "./taskOrigin";
import { useOpenTasksFilter } from "./taskChips";
import { taskMentionsDraft } from "./taskMentions";
import { useTaskBadges } from "./useTaskBadges";
import { useTaskOrder } from "./useTaskOrder";
import { useWorkspaceTasks } from "./useWorkspaceTasks";

export type TaskViewModel = TaskWorkspaceTask;
export type TaskWorkspacePanelProps = TaskWorkspaceProps;
export const TaskWorkspacePanel = TaskWorkspace;

/** The Label filter's option for Tasks carrying no label at all. */
const NO_LABEL_OPTION = "comma:no-label";

/**
 * Filter-menu edits, tied to the deep link they were made under: a fresh
 * `?label=` / `?platform=` link supersedes them, so a chip clicked elsewhere
 * always lands on exactly the narrowing it names.
 */
interface FilterEdits {
  link: string;
  label?: ReadonlySet<string> | undefined;
  platform?: ReadonlySet<string> | undefined;
  clientPlatform?: ReadonlySet<string> | undefined;
}

const NO_LINK = "||";

function allOptionIds(options: readonly TaskFilterOption[]): ReadonlySet<string> {
  return new Set(options.map((option) => option.id));
}

/** `undefined` once every option is selected: the section no longer narrows. */
function narrowingOnly(
  selected: ReadonlySet<string>,
  options: readonly TaskFilterOption[]
): ReadonlySet<string> | undefined {
  return options.every((option) => selected.has(option.id)) ? undefined : selected;
}

export function TasksRoute() {
  const isDark = useCommaUiThemeName() === "Dark mode";
  const auth = useCommaAuth();
  const navigate = useNavigate();
  const api = useChatApi();
  const {
    activeGroupId,
    loadMore,
    loadMoreState,
    loading,
    result,
    retryTasks,
    taskLoadError,
    tasks,
  } = useWorkspaceTasks();
  const { orders, setBucketOrder } = useTaskOrder(api, activeGroupId, tasks);
  const messages = useCommaMessages();

  // `?label=<id>` / `?platform=<origin>`: a chip on a card or in a Task's
  // properties panel, or Settings › Labels › View labeled tasks. The link
  // seeds the filter (the toolbar's Filter icon shows it); editing the
  // filter menu takes over from it.
  const {
    label: labelParam,
    platform: platformParam,
    status: statusParam,
    clientPlatform: clientPlatformParam,
  } = useSearch({ strict: false });
  const platformLink = taskOriginKey(platformParam);
  const link = `${labelParam ?? ""}|${platformParam ?? ""}|${clientPlatformParam ?? ""}`;
  const [edits, setEdits] = useState<FilterEdits>({ link });
  const current = edits.link === link ? edits : undefined;
  const labelSelection = useMemo(
    () => current?.label ?? (labelParam ? new Set([labelParam]) : undefined),
    [current, labelParam]
  );
  const platformSelection = useMemo(
    () =>
      current?.platform ?? (platformLink ? new Set<string>([platformLink]) : undefined),
    [current, platformLink]
  );

  const clientPlatformSelection = useMemo(
    () =>
      current?.clientPlatform ??
      (clientPlatformParam ? new Set([clientPlatformParam]) : undefined),
    [current, clientPlatformParam]
  );
  const openTasksFilter = useOpenTasksFilter();
  const { catalog, catalogById, metaById, renderTaskBadges } = useTaskBadges(
    api,
    activeGroupId,
    tasks,
    openTasksFilter
  );
  const hasLabels = catalogById.size > 0;

  // A deleted label leaves its id on the Tasks it was applied to; only ids
  // the catalog still knows count as labels here. A Task whose metadata is
  // absent from an older cache counts for nothing until the projection refreshes.
  const knownLabels = useCallback(
    (conversationId: string): readonly string[] | undefined => {
      const labels = metaById.get(conversationId)?.labels;
      return labels?.filter((id) => catalogById.has(id));
    },
    [catalogById, metaById]
  );
  const labelOptions = useMemo<TaskFilterOption[]>(() => {
    const counts = new Map<string, number>();
    let unlabeled = 0;
    for (const task of tasks) {
      const labels = knownLabels(task.conversationId);
      if (!labels) continue;
      if (labels.length === 0) unlabeled += 1;
      for (const id of labels) counts.set(id, (counts.get(id) ?? 0) + 1);
    }
    return [
      ...(catalog?.labels ?? []).map((label) => ({
        count: counts.get(label.id) ?? 0,
        icon: <LabelDot className="size-md" color={label.color} />,
        id: label.id,
        label: label.name,
      })),
      {
        count: unlabeled,
        icon: <span aria-hidden className="size-md" />,
        id: NO_LABEL_OPTION,
        label: messages.tasks_filter_no_label(),
      },
    ];
  }, [catalog, knownLabels, messages, tasks]);

  const platformOptions = useMemo<TaskFilterOption[]>(() => {
    const counts = new Map<TaskOriginKey, number>();
    for (const task of tasks) {
      if (task.origin) counts.set(task.origin, (counts.get(task.origin) ?? 0) + 1);
    }
    return TASK_ORIGIN_KEYS.filter(
      (key) => counts.has(key) || platformSelection?.has(key)
    ).map((key) => ({
      count: counts.get(key) ?? 0,
      icon: <TaskOriginIcon className="size-4" origin={key} />,
      id: key,
      label: taskOriginLabel(messages, key),
    }));
  }, [messages, platformSelection, tasks]);

  const clientPlatformOptions = useMemo<TaskFilterOption[]>(() => {
    const counts = new Map<string, number>();
    for (const task of tasks) {
      const platform = metaById.get(task.conversationId)?.clientPlatform;
      if (platform) counts.set(platform, (counts.get(platform) ?? 0) + 1);
    }
    const names: Record<string, string> = {
      macos: messages.task_panel_platform_macos(),
      windows: messages.task_panel_platform_windows(),
      linux: messages.task_panel_platform_linux(),
      ios: messages.task_panel_platform_ios(),
      android: messages.task_panel_platform_android(),
      web: messages.task_panel_platform_web(),
      unknown: messages.task_panel_platform_unknown(),
    };
    return [...new Set([...counts.keys(), ...(clientPlatformSelection ?? [])])].map(
      (id) => ({
        id,
        label: names[id] ?? names.unknown!,
        count: counts.get(id) ?? 0,
        icon: <MacbookIcon />,
      })
    );
  }, [tasks, metaById, clientPlatformSelection, messages]);

  const edit = useCallback(
    (patch: Partial<Pick<FilterEdits, "label" | "platform" | "clientPlatform">>) => {
      setEdits({
        label: labelSelection,
        clientPlatform: clientPlatformSelection,
        link: NO_LINK,
        platform: platformSelection,
        ...patch,
      });
      if (
        labelParam !== undefined ||
        platformParam !== undefined ||
        clientPlatformParam !== undefined
      ) {
        void navigate({
          replace: true,
          search: statusParam ? { status: statusParam } : {},
          to: "/tasks",
        });
      }
    },
    [
      labelParam,
      labelSelection,
      navigate,
      platformParam,
      platformSelection,
      clientPlatformParam,
      clientPlatformSelection,
      statusParam,
    ]
  );

  const filterSections = useMemo<TaskFilterSection[]>(() => {
    const sections: TaskFilterSection[] = [];
    if (hasLabels) {
      sections.push({
        icon: <TagLabelIcon />,
        id: "label",
        label: messages.tasks_filter_label(),
        narrowed: labelSelection !== undefined,
        onChange: (selected) => edit({ label: narrowingOnly(selected, labelOptions) }),
        options: labelOptions,
        selected: labelSelection ?? allOptionIds(labelOptions),
      });
    }
    if (platformOptions.length > 0) {
      sections.push({
        icon: <SquareGridCircleIcon />,
        id: "platform",
        label: messages.tasks_filter_platform(),
        narrowed: platformSelection !== undefined,
        onChange: (selected) =>
          edit({ platform: narrowingOnly(selected, platformOptions) }),
        options: platformOptions,
        selected: platformSelection ?? allOptionIds(platformOptions),
      });
    }
    if (clientPlatformOptions.length > 0)
      sections.push({
        id: "clientPlatform",
        icon: <MacbookIcon />,
        label: messages.tasks_filter_client_platform(),
        narrowed: clientPlatformSelection !== undefined,
        selected: clientPlatformSelection ?? allOptionIds(clientPlatformOptions),
        options: clientPlatformOptions,
        onChange: (selected) =>
          edit({ clientPlatform: narrowingOnly(selected, clientPlatformOptions) }),
      });
    return sections;
  }, [
    clientPlatformOptions,
    clientPlatformSelection,
    edit,
    hasLabels,
    labelOptions,
    labelSelection,
    messages,
    platformOptions,
    platformSelection,
  ]);

  const narrowing =
    labelSelection !== undefined ||
    platformSelection !== undefined ||
    clientPlatformSelection !== undefined;
  const visibleTasks = useMemo(() => {
    if (!narrowing) return tasks;
    return tasks.filter((task) => {
      if (
        clientPlatformSelection &&
        !clientPlatformSelection.has(
          metaById.get(task.conversationId)?.clientPlatform ?? ""
        )
      )
        return false;
      if (platformSelection && !(task.origin && platformSelection.has(task.origin))) {
        return false;
      }
      if (labelSelection) {
        // Older cache entries join after the owner refresh supplies membership.
        if (!metaById.has(task.conversationId)) return false;
        const labels = knownLabels(task.conversationId) ?? [];
        const matches =
          labels.length === 0
            ? labelSelection.has(NO_LABEL_OPTION)
            : labels.some((id) => labelSelection.has(id));
        if (!matches) return false;
      }
      return true;
    });
  }, [
    knownLabels,
    labelSelection,
    metaById,
    narrowing,
    platformSelection,
    clientPlatformSelection,
    tasks,
  ]);

  const openTask = useCallback(
    (task: TaskViewModel) => {
      void navigate({
        params: {
          conversationId: task.conversationId,
          groupId: task.groupId,
          workspaceId: task.workspaceId,
        },
        to: "/tasks/$workspaceId/$groupId/$conversationId",
      });
    },
    [navigate]
  );
  const openCommaHome = useCallback(() => {
    void navigate({ to: "/" });
  }, [navigate]);

  // Hands a selection to the Comma assistant as mentions in the Home draft. The
  // Home conversation is one registry channel keyed by group/conversation, so
  // a draft written through a short-lived lease is the one the Home composer
  // shows once we navigate there (the way Drive hands over attachments).
  const registry = useChatRegistry();
  const preparation = useRef<ConversationPreparation | undefined>(undefined);
  useEffect(() => {
    const owner = new ConversationPreparation(registry);
    preparation.current = owner;
    return () => {
      owner.dispose();
      preparation.current = undefined;
    };
  }, [registry]);
  const prepareVisibleTasks = useCallback((visible: readonly TaskWorkspaceTask[]) => {
    preparation.current?.update(
      visible.map((task) => ({
        conversationId: task.conversationId,
        groupId: task.groupId,
        updatedAt: task.archiveVersion,
      }))
    );
  }, []);

  const locale = useCommaLocale();
  const askComma = useCallback(
    async (selected: readonly TaskViewModel[]) => {
      if (selected.length === 0) return;
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
          lease.channel.setDraft(
            taskMentionsDraft(selected, lease.channel.getSnapshot().draft)
          );
          await navigate({ to: "/" });
        });
      } catch (error) {
        if (!isStaleChatSessionError(error)) {
          toast.error(messages.chat_unavailable(), {
            id: "comma-tasks-ask-comma-failed",
            testId: "comma-tasks-ask-comma-failed",
          });
        }
      } finally {
        attempt.release();
      }
    },
    [locale, messages, navigate, registry]
  );

  return (
    <TaskWorkspace
      key={statusParam ?? "all"}
      initialStatus={statusParam as TaskStatusBucket | undefined}
      capabilityState="ready"
      codeClipboard={nativePlatformClipboard}
      filterSections={filterSections}
      hasMore={result?.hasMore === true}
      isDark={isDark}
      loadError={taskLoadError}
      loadMoreError={loadMoreState.error}
      loadMorePending={loadMoreState.pending}
      loading={loading}
      onAskComma={askComma}
      onChatWithComma={openCommaHome}
      onLoadMore={loadMore}
      onOpenTask={openTask}
      onVisibleTasksChange={prepareVisibleTasks}
      onRetry={result?.source === "error" ? retryTasks : undefined}
      onTaskOrderChange={setBucketOrder}
      renderTaskBadges={renderTaskBadges}
      taskOrder={orders}
      tasks={visibleTasks}
      userEmail={auth.userEmail}
    />
  );
}
