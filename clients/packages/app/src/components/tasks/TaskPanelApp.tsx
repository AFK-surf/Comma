import { taskStatusBucketLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  ChevronLeftSmallIcon,
  CommaLogoAnimation,
  LoadingIndicator,
  normalizeTaskStatus,
  ScrollArea,
  taskProgressLabel,
  taskStatusBucket,
  taskStatusIcon,
  taskUpdatedAtLabel,
  type TaskStatusBucket,
  type TaskSummaryViewModel,
} from "@comma/ui";
import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  createCommaApi,
  type CommaApiClient,
  type CommaConversation,
  type CommaConversationPreview,
} from "../../api";
import { CommaAuthGate, useCommaAuth } from "../AuthGate";
import { CommaAppearanceProvider } from "../commaAppearance";
import { ShellIconButton } from "../ShellIconButton";
import { TaskDetailsPanel } from "../chat/tasks/TaskDetailsPanel";
import { panelTabButton } from "../panelTabButton";

const TaskConversationPreview = lazy(() =>
  import("../search/TaskConversationPreview")
    .then((module) => ({ default: module.TaskConversationPreview }))
    .catch(() => ({ default: TaskConversationUnavailable }))
);

function TaskConversationUnavailable() {
  const messages = useCommaMessages();
  return <p role="alert">{messages.chat_ref_task_unavailable()}</p>;
}

type TaskPanelTarget = {
  groupId: string;
  conversationId?: string | undefined;
  workspaceId?: string | undefined;
};

type PanelScreen = "tasks" | "details" | "conversation";
const TASK_PAGE_SIZE = 20;
const TASK_MESSAGE_LIMIT = 20;
const TASK_STATUSES: readonly (TaskStatusBucket | "all")[] = [
  "all",
  "backlog",
  "in_progress",
  "needs_review",
  "done",
  "cancelled",
];

/** The same Task in the full Comma Web app, served from the panel's origin. */
function commaWebTaskUrl(workspaceId: string, groupId: string, conversationId: string) {
  const path = [workspaceId, groupId, conversationId].map(encodeURIComponent).join("/");
  return new URL(`/#/tasks/${path}`, window.location.origin).href;
}

/** The chat client's own back control, such as Telegram's `BackButton`. */
export type TaskPanelHostBackButton = {
  show: () => void;
  hide: () => void;
  onClick: (callback: () => void) => void;
  offClick: (callback: () => void) => void;
};

/** Chrome that the hosting chat client supplies around the panel. */
export type TaskPanelHost = {
  colorScheme?: "light" | "dark" | undefined;
  backButton?: TaskPanelHostBackButton | undefined;
  /** Device haptics, such as Telegram's `HapticFeedback.selectionChanged`. */
  selectionChanged?: (() => void) | undefined;
};

/** A read-only Comma Task view for an external chat's browser. */
export function TaskPanelApp({
  host,
  target,
}: {
  host?: TaskPanelHost | undefined;
  target: TaskPanelTarget;
}) {
  return (
    <CommaAppearanceProvider colorScheme={host?.colorScheme}>
      <CommaAuthGate>
        <AuthenticatedTaskPanel host={host} target={target} />
      </CommaAuthGate>
    </CommaAppearanceProvider>
  );
}

function AuthenticatedTaskPanel({
  host,
  target,
}: {
  host: TaskPanelHost | undefined;
  target: TaskPanelTarget;
}) {
  const { apiBaseUrl, productLease, sessionTransport } = useCommaAuth();
  const api = useMemo(
    () => createCommaApi({ baseUrl: apiBaseUrl, sessionTransport, token: "" }),
    [apiBaseUrl, sessionTransport]
  );

  // An account switch must discard the prior account's Task data immediately.
  return (
    <TaskPanelReader
      api={api}
      host={host}
      key={JSON.stringify([productLease, target])}
      target={target}
    />
  );
}

const SCREEN_DEPTH: Record<PanelScreen, number> = {
  tasks: 0,
  details: 1,
  conversation: 2,
};

function TaskPanelReader({
  api,
  host,
  target,
}: {
  api: CommaApiClient;
  host: TaskPanelHost | undefined;
  target: TaskPanelTarget;
}) {
  const messages = useCommaMessages();
  const backButton = host?.backButton;
  // The direction drives a push or pop transition; the first screen does not animate.
  const [navigation, setNavigation] = useState<{
    screen: PanelScreen;
    direction: "none" | "forward" | "back";
  }>({ screen: target.conversationId ? "details" : "tasks", direction: "none" });
  const { screen } = navigation;
  const setScreen = useCallback((next: PanelScreen) => {
    setNavigation((current) =>
      current.screen === next
        ? current
        : {
            screen: next,
            direction:
              SCREEN_DEPTH[next] > SCREEN_DEPTH[current.screen] ? "forward" : "back",
          }
    );
  }, []);
  // The list stays mounted once shown so returning to it keeps its page and scroll.
  const [listShown, setListShown] = useState(screen === "tasks");
  if (screen === "tasks" && !listShown) setListShown(true);
  const [conversationId, setConversationId] = useState(target.conversationId);
  const [revision, setRevision] = useState(0);
  const [conversation, setConversation] = useState<CommaConversationPreview>();
  const [previewStatus, setPreviewStatus] = useState<
    "loading" | "unavailable" | "ready"
  >("loading");
  const { groupId } = target;

  useEffect(() => {
    if (screen !== "details" || !groupId || !conversationId) return;
    const request = new AbortController();
    setConversation(undefined);
    setPreviewStatus("loading");
    void api
      .getConversationPreview(groupId, conversationId, {
        includeWorker: true,
        signal: AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]),
      })
      .then((next) => {
        if (request.signal.aborted) return;
        setConversation(next);
        setPreviewStatus("ready");
      })
      .catch(() => {
        if (request.signal.aborted) return;
        setConversation(undefined);
        setPreviewStatus("unavailable");
      });
    return () => request.abort();
  }, [api, conversationId, groupId, revision, screen]);

  function openTask(id: string) {
    setConversationId(id);
    setScreen("details");
  }

  const back = useCallback(() => {
    setNavigation((current) => ({
      screen: current.screen === "conversation" ? "details" : "tasks",
      direction: "back",
    }));
  }, []);

  useEffect(() => {
    if (!backButton) return;
    if (screen === "tasks") {
      backButton.hide();
      return;
    }
    backButton.onClick(back);
    backButton.show();
    return () => backButton.offClick(back);
  }, [back, backButton, screen]);

  useEffect(() => () => backButton?.hide(), [backButton]);

  const title =
    screen === "tasks" ? messages.tasks_title() : messages.task_panel_region();
  const canRefresh = screen === "details" && previewStatus !== "loading";

  return (
    <main className="comma-embedded-task-panel bg-main-panel-bg text-primary">
      <header className="comma-embedded-task-panel-header">
        <div className="comma-embedded-task-panel-bar">
          {screen === "tasks" || backButton ? (
            <span className="comma-embedded-task-panel-title">
              <CommaLogoAnimation
                aria-hidden="true"
                className="comma-embedded-task-panel-logo"
                paused
                size={20}
              />
              {title}
            </span>
          ) : (
            <Button
              className="comma-embedded-task-back"
              hierarchy="tertiary-gray"
              iconLeading={<ChevronLeftSmallIcon />}
              onPress={back}
              size="sm"
            >
              {screen === "conversation"
                ? messages.task_panel_back_to_details()
                : messages.tasks_all()}
            </Button>
          )}
          {canRefresh ? (
            <ShellIconButton
              icon="reload"
              label={messages.common_refresh()}
              onClick={() => setRevision((current) => current + 1)}
            />
          ) : null}
        </div>
      </header>
      <div className="comma-embedded-task-panel-stage">
        {listShown ? (
          <div
            className="comma-embedded-task-screen"
            data-direction={screen === "tasks" ? navigation.direction : undefined}
            data-inactive={screen === "tasks" ? undefined : ""}
            // Hidden without `display: none`, so the list keeps its scroll position.
            inert={screen !== "tasks"}
          >
            <TaskPanelList
              api={api}
              groupId={groupId}
              onFilterChange={host?.selectionChanged}
              onOpenTask={openTask}
            />
          </div>
        ) : null}
        {screen === "tasks" ? null : (
          <div
            className="comma-embedded-task-screen"
            data-direction={navigation.direction}
            key={screen}
          >
            {screen === "conversation" && conversation && target.workspaceId ? (
              <div className="comma-embedded-task-conversation">
                <Suspense
                  fallback={<LoadingIndicator label={messages.common_loading()} />}
                >
                  <TaskConversationPreview
                    apiClient={api}
                    messageLimit={TASK_MESSAGE_LIMIT}
                    task={{
                      conversationId: conversation.id,
                      groupId,
                      workspaceId: target.workspaceId,
                      status: conversation.status,
                      title: conversation.title,
                      updatedAt: conversation.updated_at,
                    }}
                  />
                </Suspense>
              </div>
            ) : (
              <>
                <ScrollArea className="min-h-0 flex-1" edgeEffect="none">
                  <div className="comma-embedded-task-panel-content">
                    {conversation && previewStatus === "ready" ? (
                      <>
                        <h1 className="mb-3xl break-words text-xl font-semibold text-balance">
                          {conversation.title}
                        </h1>
                        <TaskDetailsPanel
                          api={api}
                          canDone={false}
                          conversation={conversation}
                          doneState="idle"
                          groupId={conversation.group_id}
                          layout="embedded"
                          open
                          {...(conversation.bound_worker
                            ? {
                                worker: {
                                  participantId:
                                    conversation.bound_worker.participant_id,
                                  actorId: conversation.bound_worker.actor_id,
                                  name: conversation.bound_worker.name,
                                },
                              }
                            : {})}
                        />
                      </>
                    ) : previewStatus === "loading" && groupId && conversationId ? (
                      <output className="flex items-center gap-md text-sm text-tertiary">
                        <LoadingIndicator label={messages.common_loading()} />
                      </output>
                    ) : (
                      <div className="flex flex-col items-start gap-xl" role="alert">
                        <p className="text-sm text-tertiary">
                          {messages.chat_ref_task_unavailable()}
                        </p>
                        <Button
                          hierarchy="secondary-gray"
                          onPress={() => setRevision((current) => current + 1)}
                          size="sm"
                        >
                          {messages.common_retry()}
                        </Button>
                      </div>
                    )}
                  </div>
                </ScrollArea>
                {conversation && previewStatus === "ready" ? (
                  <footer className="comma-embedded-task-panel-footer">
                    <div className="comma-embedded-task-panel-bar comma-embedded-task-panel-actions">
                      <p className="text-sm text-tertiary text-pretty">
                        {messages.task_panel_chat_hint()}
                      </p>
                      {target.workspaceId ? (
                        <Button
                          className="w-full"
                          hierarchy="secondary-gray"
                          onPress={() => setScreen("conversation")}
                          size="md"
                        >
                          {messages.task_panel_view_conversation()}
                        </Button>
                      ) : null}
                      {target.workspaceId ? (
                        <a
                          className="comma-embedded-task-open-in-comma"
                          href={commaWebTaskUrl(
                            target.workspaceId,
                            groupId,
                            conversation.id
                          )}
                          rel="noopener"
                          target="_blank"
                        >
                          {messages.task_panel_open_in_comma_web()}
                        </a>
                      ) : null}
                    </div>
                  </footer>
                ) : null}
              </>
            )}
          </div>
        )}
      </div>
    </main>
  );
}

type TaskPageState =
  | { status: "loading" }
  | { status: "error" }
  | {
      status: "ready";
      tasks: CommaConversation[];
      nextCursor?: string;
      hasMore: boolean;
    };

function TaskPanelList({
  api,
  groupId,
  onFilterChange,
  onOpenTask,
}: {
  api: CommaApiClient;
  groupId: string;
  onFilterChange: (() => void) | undefined;
  onOpenTask: (id: string) => void;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [state, setState] = useState<TaskPageState>({ status: "loading" });
  const [filter, setFilter] = useState<TaskStatusBucket | "all">("all");
  const [revision, setRevision] = useState(0);
  const [loadingMore, setLoadingMore] = useState(false);
  const [moreError, setMoreError] = useState(false);
  const requestRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!groupId) {
      setState({ status: "error" });
      return;
    }
    const request = new AbortController();
    requestRef.current = request;
    setState({ status: "loading" });
    setLoadingMore(false);
    setMoreError(false);
    void api
      .listConversationPage(groupId, {
        limit: TASK_PAGE_SIZE,
        signal: AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]),
      })
      .then((page) => {
        if (request.signal.aborted) return;
        setState({
          status: "ready",
          tasks: page.data.filter((item) => item.kind === "agent_task"),
          hasMore: page.hasMore,
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
        });
      })
      .catch(() => {
        if (!request.signal.aborted) setState({ status: "error" });
      });
    return () => request.abort();
  }, [api, groupId, revision]);

  async function loadMore() {
    if (state.status !== "ready" || !state.nextCursor || loadingMore) return;
    const request = requestRef.current;
    if (!request || request.signal.aborted) return;
    setLoadingMore(true);
    setMoreError(false);
    try {
      const page = await api.listConversationPage(groupId, {
        cursor: state.nextCursor,
        limit: TASK_PAGE_SIZE,
        signal: AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]),
      });
      if (request.signal.aborted) return;
      setState({
        status: "ready",
        tasks: [
          ...state.tasks,
          ...page.data.filter((item) => item.kind === "agent_task"),
        ],
        hasMore: page.hasMore,
        ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
      });
    } catch {
      if (!request.signal.aborted) setMoreError(true);
    } finally {
      if (!request.signal.aborted) setLoadingMore(false);
    }
  }

  const tasks = state.status === "ready" ? state.tasks : [];
  const visibleTasks = tasks.filter(
    (task) => filter === "all" || taskStatusBucket(task.status) === filter
  );

  return (
    <>
      {state.status === "ready" ? (
        <ScrollArea
          className="comma-embedded-task-filter-bar"
          edgeEffect="mask"
          orientation="horizontal"
          scrollbarVisibility="scrollbar-hover"
        >
          <fieldset
            aria-label={messages.tasks_filter_status()}
            className="comma-embedded-task-filters"
          >
            {TASK_STATUSES.map((bucket) => (
              <button
                aria-pressed={filter === bucket}
                className={panelTabButton(filter === bucket)}
                key={bucket}
                onClick={() => {
                  if (filter === bucket) return;
                  setFilter(bucket);
                  onFilterChange?.();
                }}
                type="button"
              >
                {bucket === "all"
                  ? messages.tasks_all()
                  : taskStatusBucketLabel(bucket, locale)}
              </button>
            ))}
          </fieldset>
        </ScrollArea>
      ) : null}
      <ScrollArea className="min-h-0 flex-1" edgeEffect="none">
        <div
          className="comma-embedded-task-panel-content"
          data-below-filters={state.status === "ready" ? "" : undefined}
        >
          {state.status === "ready" ? (
            <>
              <ul className="comma-embedded-task-list">
                {visibleTasks.map((task) => (
                  <li key={task.id}>
                    <TaskPanelRow
                      onOpen={() => onOpenTask(task.id)}
                      status={task.status}
                      task={{
                        id: task.id,
                        title: task.title,
                        statusBucket: taskStatusBucket(task.status),
                        updatedAt: task.updated_at ?? 0,
                        activityStatus: task.activity_status ?? "idle",
                        freshness: task.freshness?.state ?? "unknown",
                      }}
                    />
                  </li>
                ))}
              </ul>
              {visibleTasks.length === 0 ? (
                <p className="py-3xl text-sm text-tertiary">
                  {tasks.length === 0
                    ? messages.tasks_empty()
                    : messages.tasks_filter_no_matches()}
                </p>
              ) : null}
              {state.hasMore && state.nextCursor ? (
                <div className="mt-3xl flex flex-col items-stretch gap-md">
                  {moreError ? (
                    <p className="text-sm text-tertiary" role="alert">
                      {messages.tasks_load_failed()}
                    </p>
                  ) : null}
                  <Button
                    hierarchy="tertiary-gray"
                    isDisabled={loadingMore}
                    onPress={() => void loadMore()}
                    size="md"
                  >
                    {loadingMore
                      ? messages.common_loading_more()
                      : messages.common_load_more()}
                  </Button>
                </div>
              ) : null}
            </>
          ) : state.status === "loading" ? (
            <output
              aria-label={messages.common_loading()}
              className="comma-embedded-task-loading"
            >
              <CommaLogoAnimation aria-hidden="true" size={40} />
            </output>
          ) : (
            <div className="flex flex-col items-start gap-xl" role="alert">
              <p className="text-sm text-tertiary">{messages.tasks_unavailable()}</p>
              <Button
                hierarchy="secondary-gray"
                onPress={() => setRevision((current) => current + 1)}
                size="sm"
              >
                {messages.common_retry()}
              </Button>
            </div>
          )}
        </div>
      </ScrollArea>
    </>
  );
}

/**
 * One Task as a flat, full-bleed list row, the way a chat client lists its own
 * items. The board's floating card belongs to the kanban, not an embedded sheet.
 */
function TaskPanelRow({
  onOpen,
  status,
  task,
}: {
  onOpen: () => void;
  status: string;
  task: TaskSummaryViewModel;
}) {
  const locale = useCommaLocale();
  const progress = taskProgressLabel(task, locale);
  return (
    <button
      aria-label={task.title}
      className="comma-embedded-task-row"
      // A cancelled Task stopped on purpose; only a failed one reads as an error.
      data-quiet-status={
        ["cancelled", "canceled"].includes(normalizeTaskStatus(status)) ? "" : undefined
      }
      onClick={onOpen}
      type="button"
    >
      <span aria-hidden className="comma-embedded-task-row-icon">
        {taskStatusIcon(task.statusBucket)}
      </span>
      <span className="comma-embedded-task-row-body">
        <span className="comma-embedded-task-row-title">{task.title}</span>
        {progress ? (
          <span className="comma-embedded-task-row-meta comma-shiny-text">
            {progress}
          </span>
        ) : null}
        <span className="comma-embedded-task-row-meta">
          {taskUpdatedAtLabel(task.updatedAt, locale)}
        </span>
      </span>
    </button>
  );
}
