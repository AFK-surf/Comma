import {
  TaskArchiveMenu,
  type TaskArchiveAction,
} from "../task-workspace/TaskArchiveMenu";
import { formatDate, taskActivityLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  forwardRef,
  type CSSProperties,
  type MouseEvent as ReactMouseEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { TaskCard, TaskCardMeta } from "../task-board";
import { taskStatusIcon } from "../task-workspace/TaskSummaryCard";
import { ScrollArea } from "../scroll-area";
import { isImeKeyEvent } from "../utils";
import {
  StatusIndicator,
  indicatorIdToTaskStatus,
  taskStatusToIndicatorId,
} from "../status-indicator";
import {
  ArrowLeftIcon,
  ArrowUpIcon,
  CircleInfoIcon,
  ListChecksIcon,
  LoaderIcon,
  PanelRightIcon,
  SparklesIcon,
  XIcon,
} from "../icons";

export type SideChatTheme = "Light mode" | "Dark mode";

export type SideChatSurfaceProps = {
  bottom?: number;
  children: ReactNode;
  className?: string;
  height?: number;
  left?: number;
  phase?: string;
  presentationReady?: boolean;
  progress?: number;
  theme?: SideChatTheme;
  width?: number;
} & React.HTMLAttributes<HTMLElement>;

export const SideChatSurface = forwardRef<HTMLElement, SideChatSurfaceProps>(
  function SideChatSurface(
    {
      bottom,
      children,
      className,
      height,
      left,
      phase = "open",
      presentationReady = true,
      progress = 1,
      style,
      theme,
      width,
      ...props
    }: SideChatSurfaceProps,
    ref
  ) {
    const geometry = {
      ...(bottom !== undefined ? { bottom } : {}),
      ...(height !== undefined ? { height } : {}),
      ...(left !== undefined ? { left } : {}),
      ...(width !== undefined ? { width } : {}),
      ...style,
    };
    return (
      <main
        className={["comma-side-chat-host", className].filter(Boolean).join(" ")}
        data-phase={phase}
        data-presentation-ready={presentationReady}
        data-progress={progress}
        ref={ref}
        {...(theme ? { "data-theme": theme } : {})}
        style={geometry}
        {...props}
      >
        {children}
      </main>
    );
  }
);

export type SideChatPanelProps = {
  cards?: ReactNode;
  cardsVisible?: boolean;
  children: ReactNode;
};

export function SideChatPanel({
  cards,
  cardsVisible = false,
  children,
}: SideChatPanelProps) {
  return (
    <div className="comma-side-chat-panel">
      <div
        className="comma-side-chat-conversation"
        data-content-mode={cardsVisible ? "cards" : "messages"}
      >
        <div
          aria-hidden={cardsVisible}
          className="comma-side-chat-messages"
          inert={cardsVisible ? true : undefined}
        >
          {children}
        </div>
        {cardsVisible ? cards : null}
      </div>
    </div>
  );
}

export type SideChatStatusProps = {
  action?: ReactNode;
  detail?: string;
  onRequiredHeight?: (height: number) => void;
  title: string;
};

export function SideChatStatus({
  action,
  detail,
  onRequiredHeight,
  title,
}: SideChatStatusProps) {
  const contentRef = useRef<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    const content = contentRef.current;
    if (!content || !onRequiredHeight) return;
    const report = () => onRequiredHeight(Math.ceil(content.scrollHeight) + 24);
    report();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(report);
    observer.observe(content);
    return () => observer.disconnect();
  }, [onRequiredHeight]);
  return (
    <div className="comma-side-chat-status">
      <div className="comma-side-chat-status-content" ref={contentRef}>
        <div className="comma-side-chat-empty-mark" aria-hidden>
          <SparklesIcon className="size-4" />
        </div>
        <strong>{title}</strong>
        {detail ? <p>{detail}</p> : null}
        {action}
      </div>
    </div>
  );
}

export type SideChatComposerProps = {
  disabled?: boolean;
  onSubmit: (value: string) => void;
  onTextareaHeightChange?: (height: number) => void;
  onValueChange: (value: string) => void;
  placeholder?: string;
  value: string;
};

const SIDE_CHAT_COMPOSER_LINE_HEIGHT = 20;
const SIDE_CHAT_COMPOSER_MAX_ROWS = 4;
const SIDE_CHAT_COMPOSER_MAX_HEIGHT =
  SIDE_CHAT_COMPOSER_LINE_HEIGHT * SIDE_CHAT_COMPOSER_MAX_ROWS;

export function SideChatComposer({
  disabled = false,
  onSubmit,
  onTextareaHeightChange,
  onValueChange,
  placeholder,
  value,
}: SideChatComposerProps) {
  const messages = useCommaMessages();
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const [multiline, setMultiline] = useState(false);

  const resize = () => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    const renderedHeight = textarea.getBoundingClientRect().height;
    const previousTransition = textarea.style.transition;
    const hasMeasuredHeight = textarea.style.height !== "";
    textarea.style.transition = "none";
    textarea.style.height = "0px";
    const nextHeight = Math.min(
      Math.max(textarea.scrollHeight, SIDE_CHAT_COMPOSER_LINE_HEIGHT),
      SIDE_CHAT_COMPOSER_MAX_HEIGHT
    );
    if (hasMeasuredHeight) {
      textarea.style.height = `${renderedHeight}px`;
      void textarea.offsetHeight;
    }
    textarea.style.transition = previousTransition;
    textarea.style.height = `${nextHeight}px`;
    textarea.style.overflowY =
      textarea.scrollHeight > SIDE_CHAT_COMPOSER_MAX_HEIGHT ? "auto" : "hidden";
    setMultiline(nextHeight > SIDE_CHAT_COMPOSER_LINE_HEIGHT);
    onTextareaHeightChange?.(nextHeight);
  };

  useLayoutEffect(resize, [value, onTextareaHeightChange]);

  const submit = () => {
    const nextValue = value.trim();
    if (!disabled && nextValue) onSubmit(nextValue);
  };

  const handleKeyDown = (event: ReactKeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key !== "Enter" || event.shiftKey || isImeKeyEvent(event.nativeEvent)) {
      return;
    }
    event.preventDefault();
    submit();
  };

  return (
    <div
      className="comma-side-chat-input"
      data-disabled={disabled || undefined}
      data-multiline={multiline}
    >
      <textarea
        aria-label={messages.side_chat_ai_prompt()}
        disabled={disabled}
        onChange={(event) => onValueChange(event.target.value)}
        onKeyDown={handleKeyDown}
        placeholder={placeholder ?? messages.chat_side_composer_placeholder()}
        ref={textareaRef}
        rows={1}
        value={value}
      />
      <button
        aria-label={messages.side_chat_send_message()}
        disabled={disabled || value.trim().length === 0}
        onClick={submit}
        type="button"
      >
        <ArrowUpIcon className="size-5" />
      </button>
    </div>
  );
}

export type SideChatTaskStatus =
  | "backlog"
  | "in_progress"
  | "needs_review"
  | "done"
  | "cancelled";
export type SideChatTask = {
  archiveAction?: TaskArchiveAction | undefined;
  activityStatus: string;
  /** The Task's label and platform chips, as on every other Task card. */
  badges?: ReactNode | undefined;
  conversationId: string;
  createdAt: number;
  groupId: string;
  id: string;
  lastMessage?: { content: string } | undefined;
  statusBucket: SideChatTaskStatus;
  title: string;
  workspaceId: string;
};
export type SideChatCardsCapabilityState =
  | { status: "planned" }
  | { status: "loading" }
  | { message: string; onRefresh: () => unknown; status: "error" }
  | {
      onRefresh?: () => unknown;
      refreshing?: boolean;
      status: "ready";
      tasks: readonly SideChatTask[];
    };

const STATUS_COLUMN_DEFINITIONS = [
  { bucket: "backlog", icon: taskStatusIcon("backlog") },
  { bucket: "in_progress", icon: taskStatusIcon("in_progress") },
  { bucket: "needs_review", icon: taskStatusIcon("needs_review") },
  { bucket: "done", icon: taskStatusIcon("done") },
  { bucket: "cancelled", icon: taskStatusIcon("cancelled") },
] as const;

function useStatusColumns() {
  const messages = useCommaMessages();
  return [
    {
      ...STATUS_COLUMN_DEFINITIONS[0],
      label: messages.tasks_backlog(),
    },
    {
      ...STATUS_COLUMN_DEFINITIONS[1],
      label: messages.tasks_in_progress(),
    },
    {
      ...STATUS_COLUMN_DEFINITIONS[2],
      label: messages.tasks_needs_review(),
    },
    {
      ...STATUS_COLUMN_DEFINITIONS[3],
      label: messages.tasks_done(),
    },
    {
      ...STATUS_COLUMN_DEFINITIONS[4],
      label: messages.tasks_cancelled(),
    },
  ] as const;
}
const EMPTY_TASKS: readonly SideChatTask[] = [];
const SIDE_CHAT_CARDS_STATE_HEIGHT = 140;
const SIDE_CHAT_CARDS_LIST_CHROME_HEIGHT = 59;
const SIDE_CHAT_CARDS_DETAIL_CHROME_HEIGHT = 0;
const SIDE_CHAT_TASK_DETAIL_HEADER_HEIGHT = 40;

function scrollAreaNaturalContentHeight(viewport: HTMLDivElement | null) {
  const content = viewport?.querySelector<HTMLElement>(
    ':scope > [data-slot="scroll-area-content"]'
  );
  if (!content) return 0;
  return Math.ceil(
    Math.max(content.getBoundingClientRect().height, content.scrollHeight)
  );
}

export function SideChatCardsPanel({
  capability,
  onOpenTask,
  onRequiredHeight,
}: {
  capability: SideChatCardsCapabilityState;
  onOpenTask?: (task: SideChatTask, event: ReactMouseEvent<HTMLButtonElement>) => void;
  onRequiredHeight?: (height: number) => void;
}) {
  const messages = useCommaMessages();
  const [selectedBucket, setSelectedBucket] =
    useState<SideChatTaskStatus>("in_progress");
  const [selectedTaskId, setSelectedTaskId] = useState<string>();
  const tasks = capability.status === "ready" ? capability.tasks : EMPTY_TASKS;
  const tasksByBucket = useMemo(() => groupTasks(tasks), [tasks]);
  const selectedTask = tasks.find((task) => task.id === selectedTaskId);
  const [deckRequiredHeight, setDeckRequiredHeight] = useState(
    SIDE_CHAT_CARDS_STATE_HEIGHT
  );
  const requestedRefresh = useRef(false);
  const refresh =
    capability.status === "ready" || capability.status === "error"
      ? capability.onRefresh
      : undefined;
  useEffect(() => {
    if (requestedRefresh.current || !refresh) return;
    requestedRefresh.current = true;
    void refresh();
  }, [refresh]);
  useEffect(() => {
    if (selectedTaskId && !tasks.some((task) => task.id === selectedTaskId))
      setSelectedTaskId(undefined);
  }, [selectedTaskId, tasks]);
  useLayoutEffect(() => {
    onRequiredHeight?.(
      deckRequiredHeight +
        (selectedTask
          ? SIDE_CHAT_CARDS_DETAIL_CHROME_HEIGHT
          : SIDE_CHAT_CARDS_LIST_CHROME_HEIGHT)
    );
  }, [deckRequiredHeight, onRequiredHeight, selectedTask]);
  return (
    <section
      aria-label={messages.side_chat_task_cards()}
      className="comma-side-chat-cards"
      data-capability={
        capability.status === "planned" ? "needs-capability" : capability.status
      }
    >
      <div className="comma-side-chat-cards-deck">
        {selectedTask ? (
          <SideChatTaskDetail
            onContentHeightChange={setDeckRequiredHeight}
            onBack={() => setSelectedTaskId(undefined)}
            task={selectedTask}
          />
        ) : (
          <div
            className="comma-side-chat-cards-column"
            data-bucket={selectedBucket}
            key={`${selectedBucket}:${capability.status}`}
            role="tabpanel"
          >
            <SideChatCardsColumn
              bucket={selectedBucket}
              capability={capability}
              onContentHeightChange={setDeckRequiredHeight}
              {...(onOpenTask ? { onOpenTask } : {})}
              onSelectTask={setSelectedTaskId}
              tasks={tasksByBucket.get(selectedBucket) ?? []}
            />
          </div>
        )}
      </div>
      {!selectedTask ? (
        <div className="comma-side-chat-cards-tabs">
          <StatusIndicator
            aria-label={messages.side_chat_task_status()}
            value={taskStatusToIndicatorId(selectedBucket)}
            onChange={(id) => {
              const bucket = indicatorIdToTaskStatus(id);
              if (bucket !== "archived") setSelectedBucket(bucket);
            }}
          />
        </div>
      ) : null}
    </section>
  );
}

function SideChatCardsColumn({
  bucket,
  capability,
  onContentHeightChange,
  onOpenTask,
  onSelectTask,
  tasks,
}: {
  bucket: SideChatTaskStatus;
  capability: SideChatCardsCapabilityState;
  onContentHeightChange: (height: number) => void;
  onOpenTask?: (task: SideChatTask, event: ReactMouseEvent<HTMLButtonElement>) => void;
  onSelectTask: (id: string) => void;
  tasks: readonly SideChatTask[];
}) {
  const messages = useCommaMessages();
  const column = useStatusColumns().find((item) => item.bucket === bucket)!;
  const emptyTitle = {
    backlog: messages.side_chat_no_backlog_tasks(),
    cancelled: messages.side_chat_no_cancelled_tasks(),
    done: messages.side_chat_no_done_tasks(),
    in_progress: messages.side_chat_no_in_progress_tasks(),
    needs_review: messages.side_chat_no_review_tasks(),
  }[bucket];
  const scrollViewportRef = useRef<HTMLDivElement>(null);
  const reportScrollHeight = useCallback(() => {
    const height = scrollAreaNaturalContentHeight(scrollViewportRef.current);
    if (height > 0) onContentHeightChange(height);
  }, [onContentHeightChange]);
  useLayoutEffect(() => {
    if (capability.status !== "ready" || tasks.length === 0) {
      onContentHeightChange(SIDE_CHAT_CARDS_STATE_HEIGHT);
      return;
    }
    reportScrollHeight();
  }, [capability.status, onContentHeightChange, reportScrollHeight, tasks]);
  if (capability.status === "planned")
    return (
      <CardsState
        capability="needs-capability"
        detail={messages.side_chat_cards_planned_detail()}
        icon={<ListChecksIcon className="size-5" />}
        title={messages.side_chat_cards_planned_title()}
      />
    );
  if (capability.status === "loading")
    return (
      <CardsState
        capability="loading"
        icon={<LoaderIcon className="size-5 animate-spin" />}
        title={messages.side_chat_loading_tasks()}
      />
    );
  if (capability.status === "error")
    return (
      <CardsState
        capability="error"
        detail={capability.message}
        icon={<CircleInfoIcon className="size-5" />}
        onRefresh={capability.onRefresh}
        title={messages.side_chat_tasks_unavailable()}
      />
    );
  if (tasks.length === 0)
    return (
      <CardsState
        capability="ready"
        icon={column.icon}
        {...(!capability.refreshing && capability.onRefresh
          ? { onRefresh: capability.onRefresh }
          : {})}
        title={emptyTitle}
      />
    );
  return (
    <>
      <ScrollArea
        className="comma-side-chat-cards-scroll"
        contentClassName="comma-side-chat-cards-list"
        edgeEffect="none"
        onContentResize={reportScrollHeight}
        orientation="vertical"
        ref={scrollViewportRef}
      >
        {tasks.map((task, index) => (
          <TaskArchiveMenu key={task.id} action={task.archiveAction}>
            <button
              aria-label={messages.side_chat_open_task({ title: task.title })}
              className="comma-side-chat-task-card-button"
              key={task.id}
              onClick={(event) =>
                onOpenTask ? onOpenTask(task, event) : onSelectTask(task.id)
              }
              style={{ "--comma-side-chat-card-index": index } as CSSProperties}
              type="button"
            >
              <SideChatTaskCard task={task} />
            </button>
          </TaskArchiveMenu>
        ))}
      </ScrollArea>
      {capability.refreshing ? (
        <output aria-live="polite" className="comma-side-chat-cards-refreshing">
          <LoaderIcon className="size-3.5 animate-spin" />{" "}
          {messages.side_chat_refreshing_tasks()}
        </output>
      ) : null}
    </>
  );
}

function CardsState({
  capability,
  detail,
  icon,
  onRefresh,
  title,
}: {
  capability: "error" | "loading" | "needs-capability" | "ready";
  detail?: string;
  icon: ReactNode;
  onRefresh?: () => unknown;
  title: string;
}) {
  const messages = useCommaMessages();
  return (
    <output className="comma-side-chat-cards-state" data-capability={capability}>
      <span className="comma-side-chat-cards-state-icon" aria-hidden>
        {icon}
      </span>
      <strong>{title}</strong>
      {detail ? <span>{detail}</span> : null}
      {onRefresh ? (
        <button onClick={() => void onRefresh()} type="button">
          {messages.common_refresh()}
        </button>
      ) : null}
    </output>
  );
}

function SideChatTaskCard({ task }: { task: SideChatTask }) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const createdAt = useFormattedCreatedAt(task.createdAt);
  const activityLabel = taskActivityLabel(task.activityStatus, locale);
  // Same progress-line rule as the Task card: a running task always reports
  // progress, and while it runs the line shimmers. An idle activity still
  // means running — the worker just has nothing new to say this second — so
  // it falls back to the status rather than dropping the line.
  const meta =
    task.statusBucket !== "in_progress" ? undefined : (
      <TaskCardMeta textClassName="comma-shiny-text">
        {task.lastMessage?.content || activityLabel || messages.tasks_in_progress()}
      </TaskCardMeta>
    );
  return (
    <TaskCard
      badges={task.badges}
      footer={createdAt}
      icon={taskStatusIcon(task.statusBucket)}
      interactive
      meta={meta}
      title={task.title}
    />
  );
}

function SideChatTaskDetail({
  onContentHeightChange,
  onBack,
  task,
}: {
  onContentHeightChange: (height: number) => void;
  onBack: () => void;
  task: SideChatTask;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const column = useStatusColumns().find((item) => item.bucket === task.statusBucket);
  const createdAt = useFormattedCreatedAt(task.createdAt);
  const activityLabel = taskActivityLabel(task.activityStatus, locale);
  const scrollViewportRef = useRef<HTMLDivElement>(null);
  const reportScrollHeight = useCallback(() => {
    const contentHeight = scrollAreaNaturalContentHeight(scrollViewportRef.current);
    if (contentHeight > 0) {
      onContentHeightChange(contentHeight + SIDE_CHAT_TASK_DETAIL_HEADER_HEIGHT);
    }
  }, [onContentHeightChange]);
  useLayoutEffect(reportScrollHeight, [reportScrollHeight, task]);
  return (
    <article className="comma-side-chat-task-detail" data-task-id={task.id}>
      <header>
        <button
          aria-label={messages.side_chat_back_to_cards()}
          onClick={onBack}
          type="button"
        >
          <ArrowLeftIcon className="size-4" />
        </button>
        <span>{column?.label ?? messages.side_chat_task_fallback()}</span>
      </header>
      <ScrollArea
        className="comma-side-chat-task-detail-scroll"
        contentClassName="comma-side-chat-task-detail-content"
        edgeEffect="none"
        onContentResize={reportScrollHeight}
        orientation="vertical"
        ref={scrollViewportRef}
      >
        <div className="comma-side-chat-task-detail-title">
          <span aria-hidden>{taskStatusIcon(task.statusBucket)}</span>
          <h2>{task.title}</h2>
        </div>
        {task.lastMessage?.content ? <p>{task.lastMessage.content}</p> : null}
        {task.activityStatus !== "idle" ? (
          <p className="comma-side-chat-task-detail-activity">
            {activityLabel ?? messages.side_chat_task_fallback()}
          </p>
        ) : null}
        <time dateTime={new Date(normalizeTimestamp(task.createdAt)).toISOString()}>
          {createdAt}
        </time>
      </ScrollArea>
    </article>
  );
}

function groupTasks(tasks: readonly SideChatTask[]) {
  const grouped = new Map<SideChatTaskStatus, SideChatTask[]>();
  for (const column of STATUS_COLUMN_DEFINITIONS) grouped.set(column.bucket, []);
  for (const task of tasks) grouped.get(task.statusBucket)?.push(task);
  return grouped;
}
function normalizeTimestamp(timestamp: number) {
  return timestamp < 10_000_000_000 ? timestamp * 1_000 : timestamp;
}
function useFormattedCreatedAt(timestamp: number) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  if (!timestamp) return messages.tasks_created_recently();
  return messages.tasks_created_date({
    date: formatDate(new Date(normalizeTimestamp(timestamp)), locale, {
      day: "numeric",
      month: "short",
    }),
  });
}

export type SideChatDiagnosticsMetrics = {
  devicePixelRatio: number;
  devicePixelSize: { height: number; width: number };
  presentation: {
    displayId: string | number;
    offsetX: number;
    phase: string;
    progress: number;
    revision: number;
  };
  viewportSize: { height: number; width: number };
};
export type SideChatSourceFrame = {
  height: number;
  width: number;
  x: number;
  y: number;
};
export function SideChatDiagnostics({
  contentVisible,
  error,
  expanded,
  metrics,
  onDismiss,
  onRefresh,
  sourceFrame,
  theme,
}: {
  contentVisible: boolean;
  error?: string | null;
  expanded: boolean;
  metrics?: SideChatDiagnosticsMetrics | null;
  onDismiss: () => void;
  onRefresh: () => void;
  sourceFrame: SideChatSourceFrame;
  theme?: SideChatTheme;
}) {
  const style = {
    "--source-height": `${sourceFrame.height}px`,
    "--source-width": `${sourceFrame.width}px`,
    "--source-x": `${sourceFrame.x}px`,
    "--source-y": `${sourceFrame.y}px`,
  } as CSSProperties;
  const dismissBackdrop = (event: ReactPointerEvent<HTMLElement>) => {
    if (event.target === event.currentTarget) onDismiss();
  };
  return (
    <main
      aria-label="Side Chat test window"
      className="comma-side-chat-test-window"
      data-content-visible={contentVisible}
      data-expanded={expanded}
      data-source-height={sourceFrame.height}
      data-source-width={sourceFrame.width}
      data-source-x={sourceFrame.x}
      data-source-y={sourceFrame.y}
      {...(theme ? { "data-theme": theme } : {})}
      onPointerDown={dismissBackdrop}
      style={style}
    >
      <dialog
        aria-label="Side Chat diagnostics"
        aria-modal="true"
        className="comma-side-chat-test-shell"
        open
      >
        <div className="comma-side-chat-test-content">
          <header className="comma-side-chat-test-header">
            <PanelRightIcon aria-hidden className="comma-side-chat-test-title-icon" />
            <h1>测试窗口</h1>
            <button
              aria-label="Close test window"
              className="comma-side-chat-test-close"
              onClick={onDismiss}
              title="Close"
              type="button"
            >
              <XIcon aria-hidden />
            </button>
          </header>
          <div className="comma-side-chat-test-divider" />
          {metrics ? (
            <dl className="comma-side-chat-test-metrics">
              <MetricRow
                label="Window"
                value={`${metrics.viewportSize.width} × ${metrics.viewportSize.height} pt`}
              />
              <MetricRow
                label="Device pixels"
                value={`${metrics.devicePixelSize.width} × ${metrics.devicePixelSize.height}`}
              />
              <MetricRow label="DPR" value={formatNumber(metrics.devicePixelRatio)} />
              <MetricRow
                label="Presentation"
                value={`${metrics.presentation.phase} · ${Math.round(metrics.presentation.progress * 100)}%`}
              />
              <MetricRow
                label="Display / offset"
                value={`${metrics.presentation.displayId} / ${formatNumber(metrics.presentation.offsetX)} pt`}
              />
              <MetricRow
                label="Revision"
                value={String(metrics.presentation.revision)}
              />
            </dl>
          ) : (
            <output className="comma-side-chat-test-status">
              {error ?? "Reading native metrics…"}
            </output>
          )}
          <button
            className="comma-side-chat-test-refresh"
            onClick={onRefresh}
            type="button"
          >
            Refresh content
          </button>
        </div>
      </dialog>
    </main>
  );
}
function MetricRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="comma-side-chat-test-metric-row">
      <dt>{label}</dt>
      <dd>{value}</dd>
    </div>
  );
}
function formatNumber(value: number) {
  return new Intl.NumberFormat("en-US", {
    maximumFractionDigits: 2,
    minimumFractionDigits: 0,
    useGrouping: false,
  }).format(value);
}
