import { countTaskLoopRules, taskLoopRuleKey } from "@comma/core/task-loop-filter";
import { openTaskTarget } from "./openTaskTarget";
import { useNewTaskDialog } from "./station/NewTaskDialogContext";
import { useTaskLoopRuleFilter } from "./useTaskLoopRuleFilter";
import {
  taskMatchesDates,
  useTaskDateFilter,
  type TaskDateField,
  type TaskDateSelection,
  type TaskDateWindow,
} from "./useTaskDateFilter";
import { useCall } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  InfinityIcon,
  InviteIcon,
  MacbookIcon,
  SquareGridCircleIcon,
  TagLabelIcon,
} from "@comma/ui/components/icons";
import {
  type TaskStatusBucket,
  TaskWorkspace,
  type TaskFilterOption,
  type TaskFilterSection,
  type TaskFilterSectionGroup,
  type TaskWorkspaceProps,
  type TaskWorkspaceTask,
} from "@comma/ui/components/task-workspace";
import { toast } from "@comma/ui/components/toast";
import { uiClock } from "@comma/ui/clock";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ConversationPreparation } from "../chat/prepareConversations";
import { nativePlatformClipboard } from "../../nativePlatformActions";
import { useCommaAuth } from "../AuthGate";
import { isStaleChatSessionError, useChatRegistry } from "../chat/ChatProvider";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import { useCommaUiThemeName } from "../commaUiTheme";
import { LabelDot } from "./labelColor";
import { RequestPeople, requestPersonKey, requestPersonOptions } from "./requestPeople";
import { TaskStepCards } from "./taskSteps";
import {
  TASK_ORIGIN_KEYS,
  TaskOriginIcon,
  taskOriginKey,
  taskOriginLabel,
  type TaskOriginKey,
} from "./taskOrigin";
import {
  TASK_LOOP_FILTER_KEYS,
  taskLoopFilterKey,
  type TaskLoopFilterCounts,
} from "./taskLoopLabels";
import { taskLoopFilterOptions, useOpenTasksFilter } from "./taskChips";
import { taskMentionsDraft } from "./taskMentions";
import { taskSequenceEntry } from "./taskSequence";
import { useTaskBadges } from "./useTaskBadges";
import { useTaskOrder } from "./useTaskOrder";
import {
  useWorkspaceTasks,
  type TaskViewModel as WorkspaceTask,
} from "./useWorkspaceTasks";

export type TaskViewModel = TaskWorkspaceTask;
export type TaskWorkspacePanelProps = TaskWorkspaceProps;
export const TaskWorkspacePanel = TaskWorkspace;

/** The Label filter's option for Tasks carrying no label at all. */
const NO_LABEL_OPTION = "comma:no-label";

/**
 * Filter-menu edits, tied to the deep link they were made under: a fresh
 * label, platform, Loop type or rule link supersedes them, so a chip
 * clicked elsewhere always lands on exactly the narrowing it names.
 */
interface FilterEdits {
  link: string;
  label?: ReadonlySet<string> | undefined;
  platform?: ReadonlySet<string> | undefined;
  clientPlatform?: ReadonlySet<string> | undefined;
  schedule?: ReadonlySet<string> | undefined;
  loopRule?: string | undefined;
  /** Who sent the request a Task came from, or none (`requestKey`). */
  request?: ReadonlySet<string> | undefined;
  /** How recent each date must be; the menu alone sets it. */
  dates?: TaskDateSelection | undefined;
}

const NO_DATES: TaskDateSelection = {};

/**
 * The Request filter's choices: each person whose request a Task was accepted from (`requestPersonKey`), and every
 * Task not from a request.
 */
const NOT_REQUEST = "not_request";
const requestKey = (task: Pick<WorkspaceTask, "origin" | "requestedBy">) =>
  task.origin === "task_request"
    ? requestPersonKey("from", task.requestedBy ?? {})
    : NOT_REQUEST;

const NO_LINK = JSON.stringify(["", "", "", "", "", ""]);

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
  const {
    activeGroupId,
    loadMore,
    loadMoreState,
    loading,
    result,
    retryTasks,
    taskLoadError,
    taskSyncError,
    tasks,
  } = useWorkspaceTasks({ stationTasks: true });
  const { orders, setBucketOrder } = useTaskOrder(activeGroupId, tasks);
  const messages = useCommaMessages();
  const locale = useCommaLocale();

  // A deep link seeds the filter (the toolbar's Filter icon shows it). An edit
  // in the filter menu replaces it.
  // - `?label=<id>` / `?platform=<origin>`: a chip on a card or in a Task's
  //   properties panel, or Settings › Labels › View labeled tasks.
  // - `?schedule=<scheduled|event_triggered|unknown|not_scheduled>`: the Loop
  //   chip on a Task card or an Inbox row. An older `?schedule=loop` selects
  //   every Loop type.
  // - `?loopRule=<rule key>`: the trigger chip in a Task's properties panel.
  const {
    label: labelParam,
    platform: platformParam,
    status: statusParam,
    clientPlatform: clientPlatformParam,
    schedule: scheduleParam,
    loopRule: loopRuleParam,
    request: requestParam,
  } = useSearch({ strict: false });
  // A request's Task has a Request filter of its own: an older `?platform=task_request` link selects it there.
  const requestLink = platformParam === "task_request";
  const platformLink = requestLink ? undefined : taskOriginKey(platformParam);
  const link = JSON.stringify([
    labelParam ?? "",
    platformParam ?? "",
    clientPlatformParam ?? "",
    scheduleParam ?? "",
    loopRuleParam ?? "",
    requestParam ?? "",
  ]);
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

  // `?request=<person>`: a request chip on a card. An older `?platform=task_request` link selects every sender.
  const requestSelection = useMemo(
    () =>
      current?.request ??
      (requestParam
        ? new Set([requestParam])
        : requestLink
          ? new Set(
              tasks.flatMap((task) =>
                task.origin === "task_request" ? [requestKey(task)] : []
              )
            )
          : undefined),
    [current, requestLink, requestParam, tasks]
  );

  const clientPlatformSelection = useMemo(
    () =>
      current?.clientPlatform ??
      (clientPlatformParam ? new Set([clientPlatformParam]) : undefined),
    [current, clientPlatformParam]
  );
  const scheduleSelection = useMemo(
    () =>
      current?.schedule ??
      (scheduleParam === "loop"
        ? new Set(TASK_LOOP_FILTER_KEYS.filter((key) => key !== "not_scheduled"))
        : scheduleParam
          ? new Set([scheduleParam])
          : undefined),
    [current, scheduleParam]
  );
  const loopRuleSelection = current?.loopRule ?? loopRuleParam;
  const dateSelection = current?.dates ?? NO_DATES;
  // The Dates windows end when the list was last read, so a shown list holds still between reads.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const now = useMemo(() => uiClock.now(), [tasks]);
  const loopRules = useMemo(() => countTaskLoopRules(tasks), [tasks]);
  const openTasksFilter = useOpenTasksFilter();
  const { catalog, catalogById, metaById, renderTaskBadges } = useTaskBadges(
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
      (key) =>
        key !== "task_request" && (counts.has(key) || platformSelection?.has(key))
    ).map((key) => ({
      count: counts.get(key) ?? 0,
      icon: <TaskOriginIcon className="size-4" origin={key} />,
      id: key,
      label: taskOriginLabel(messages, key),
    }));
  }, [messages, platformSelection, tasks]);

  const requestOptions = useMemo<TaskFilterOption[]>(() => {
    const senders = new RequestPeople();
    let fromRequest = 0;
    for (const task of tasks) {
      if (task.origin !== "task_request") continue;
      fromRequest += 1;
      const sender = task.requestedBy;
      senders.add(requestKey(task), {
        name: sender?.name || messages.task_requests_unknown_person(),
        ...(sender?.avatar
          ? { avatar: { source: "sender-avatar", ...sender.avatar } as const }
          : {}),
      });
    }
    if (fromRequest === 0 && requestSelection === undefined) return [];
    return [
      ...requestPersonOptions(
        senders.list(locale),
        messages.tasks_filter_from_request()
      ),
      {
        count: tasks.length - fromRequest,
        id: NOT_REQUEST,
        label: messages.tasks_filter_not_request(),
      },
    ];
  }, [locale, messages, requestSelection, tasks]);

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

  const scheduleCounts = useMemo<TaskLoopFilterCounts>(() => {
    const counts = { scheduled: 0, event_triggered: 0, unknown: 0, not_scheduled: 0 };
    for (const task of tasks) counts[taskLoopFilterKey(task.loop)] += 1;
    return counts;
  }, [tasks]);
  const loopCount = tasks.length - scheduleCounts.not_scheduled;
  const scheduleOptions = useMemo(
    () => taskLoopFilterOptions(scheduleCounts, messages, scheduleSelection),
    [scheduleCounts, messages, scheduleSelection]
  );

  const edit = useCallback(
    (
      patch: Partial<
        Pick<
          FilterEdits,
          | "label"
          | "platform"
          | "clientPlatform"
          | "schedule"
          | "loopRule"
          | "request"
          | "dates"
        >
      >
    ) => {
      setEdits({
        label: labelSelection,
        clientPlatform: clientPlatformSelection,
        link: NO_LINK,
        platform: platformSelection,
        schedule: scheduleSelection,
        loopRule: loopRuleSelection,
        request: requestSelection,
        dates: dateSelection,
        ...patch,
      });
      if (
        labelParam !== undefined ||
        platformParam !== undefined ||
        clientPlatformParam !== undefined ||
        scheduleParam !== undefined ||
        loopRuleParam !== undefined ||
        requestParam !== undefined
      ) {
        void navigate({
          replace: true,
          search: statusParam ? { status: statusParam } : {},
          to: "/tasks",
        });
      }
    },
    [
      dateSelection,
      labelParam,
      labelSelection,
      navigate,
      platformParam,
      platformSelection,
      clientPlatformParam,
      clientPlatformSelection,
      scheduleParam,
      scheduleSelection,
      loopRuleParam,
      loopRuleSelection,
      requestParam,
      requestSelection,
      statusParam,
    ]
  );

  const editLoopRule = useCallback(
    (loopRule: string | undefined) => edit({ loopRule }),
    [edit]
  );
  const ruleSection = useTaskLoopRuleFilter(
    loopRules,
    tasks.length,
    loopRuleSelection,
    editLoopRule
  );

  const editDate = useCallback(
    (field: TaskDateField, window: TaskDateWindow | undefined) => {
      const { [field]: _, ...dates } = dateSelection;
      const next = window ? { ...dates, [field]: window } : dates;
      edit({ dates: Object.keys(next).length > 0 ? next : undefined });
    },
    [dateSelection, edit]
  );
  const dateGroup = useTaskDateFilter(tasks, dateSelection, now, editDate);

  const filterSections = useMemo<(TaskFilterSection | TaskFilterSectionGroup)[]>(() => {
    const sections: (TaskFilterSection | TaskFilterSectionGroup)[] = [];
    // Show trigger filters once a Task has a Loop or a link narrows by trigger.
    if (loopCount > 0 || scheduleSelection !== undefined) {
      sections.push({
        icon: <InfinityIcon />,
        id: "schedule",
        label: messages.tasks_loops(),
        narrowed: scheduleSelection !== undefined,
        onChange: (selected) =>
          edit({ schedule: narrowingOnly(selected, scheduleOptions) }),
        options: scheduleOptions,
        selected: scheduleSelection ?? allOptionIds(scheduleOptions),
      });
    }
    if (ruleSection) sections.push(ruleSection);
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
    if (requestOptions.length > 0) {
      sections.push({
        icon: <InviteIcon />,
        id: "request",
        label: messages.tasks_filter_request(),
        narrowed: requestSelection !== undefined,
        onChange: (selected) =>
          edit({ request: narrowingOnly(selected, requestOptions) }),
        options: requestOptions,
        selected: requestSelection ?? allOptionIds(requestOptions),
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
    sections.push(dateGroup);
    return sections;
  }, [
    clientPlatformOptions,
    clientPlatformSelection,
    dateGroup,
    edit,
    hasLabels,
    labelOptions,
    labelSelection,
    loopCount,
    messages,
    platformOptions,
    platformSelection,
    requestOptions,
    requestSelection,
    scheduleOptions,
    scheduleSelection,
    ruleSection,
  ]);

  const narrowing =
    labelSelection !== undefined ||
    platformSelection !== undefined ||
    requestSelection !== undefined ||
    clientPlatformSelection !== undefined ||
    scheduleSelection !== undefined ||
    loopRuleSelection !== undefined ||
    dateSelection !== NO_DATES;
  const visibleTasks = useMemo(() => {
    if (!narrowing) return tasks;
    return tasks.filter((task) => {
      if (
        loopRuleSelection !== undefined &&
        taskLoopRuleKey(task.loop) !== loopRuleSelection
      )
        return false;
      if (scheduleSelection && !scheduleSelection.has(taskLoopFilterKey(task.loop)))
        return false;
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
      if (requestSelection && !requestSelection.has(requestKey(task))) return false;
      if (!taskMatchesDates(task, dateSelection, now)) return false;
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
    dateSelection,
    knownLabels,
    labelSelection,
    metaById,
    narrowing,
    now,
    platformSelection,
    requestSelection,
    clientPlatformSelection,
    scheduleSelection,
    loopRuleSelection,
    tasks,
  ]);

  // A Task runs in Comma's cloud or a cloud sandbox from any app; only the desktop app also reaches the machines,
  // which the dialog offers when they are online.
  const newTask = useNewTaskDialog();
  const shownWorkspace = result?.activeWorkspaceId;
  const openTask = useCallback(
    (task: TaskViewModel, shown: readonly TaskViewModel[]) => {
      void navigate({
        ...openTaskTarget(task),
        state: { taskSequence: shown.map(taskSequenceEntry) },
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
  const call = useCall();
  const preparation = useRef<ConversationPreparation | undefined>(undefined);
  useEffect(() => {
    const owner = new ConversationPreparation(registry, call);
    preparation.current = owner;
    return () => {
      owner.dispose();
      preparation.current = undefined;
    };
  }, [call, registry]);
  const prepareVisibleTasks = useCallback((visible: readonly TaskWorkspaceTask[]) => {
    // A Task a station hosts has no Salix conversation to prepare.
    preparation.current?.update(
      visible.flatMap((task) =>
        task.conversationId.startsWith("station:")
          ? []
          : [
              {
                conversationId: task.conversationId,
                groupId: task.groupId,
                updatedAt: task.archiveVersion,
              },
            ]
      )
    );
  }, []);

  const askComma = useCallback(
    async (selected: readonly TaskViewModel[]) => {
      if (selected.length === 0) return;
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

  // Running cards show their Workers' latest steps.
  return (
    <TaskStepCards active>
      <TaskWorkspace
        key={statusParam ?? "all"}
        initialStatus={statusParam as TaskStatusBucket | undefined}
        capabilityState="ready"
        codeClipboard={nativePlatformClipboard}
        filterSections={filterSections}
        hasMore={result?.hasMore === true}
        isDark={isDark}
        loadError={taskLoadError ?? taskSyncError}
        loadMoreError={loadMoreState.error}
        loadMorePending={loadMoreState.pending}
        loading={loading}
        onAskComma={askComma}
        onChatWithComma={openCommaHome}
        onLoadMore={loadMore}
        onOpenTask={openTask}
        {...(shownWorkspace
          ? { onCreateTask: () => newTask.open(shownWorkspace) }
          : {})}
        onVisibleTasksChange={prepareVisibleTasks}
        onRetry={result?.source === "error" ? retryTasks : undefined}
        onTaskOrderChange={setBucketOrder}
        renderTaskBadges={renderTaskBadges}
        taskOrder={orders}
        tasks={visibleTasks}
        userEmail={auth.userEmail}
      />
    </TaskStepCards>
  );
}
