import { uiClock } from "@comma/ui/clock";
import { taskStatusBucketLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { ChevronRightSmallIcon } from "@comma/ui/components/icons";
import { HOVER_PANEL_ITEM } from "@comma/ui/components/hover-card";
import {
  cloneElement,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactElement,
  type ReactNode,
  type RefObject,
} from "react";
import type { SessionHistoryInput } from "../../session-history/useSessionHistory";
import { useChatProductLease } from "../../ChatProvider";
import type { InlineTaskLinkAdapter } from "../inline/MessageInlineElements";
import {
  MAX_FOCUS_TASK_FEEDS,
  type ActivityFocus,
  type ActivityFocusTask,
} from "./activityFocus";
import { WorkerModelMark } from "./WorkerModelMark";
import type { WorkerProgress } from "./workerProgress";
import {
  stepWords,
  useWorkerSteps,
  type ShownStep,
  type WorkerStepsView,
} from "./useWorkerSteps";

/** This surface's link to a Task: a route link on Home. */
export type TaskLink = (
  task: ActivityFocusTask
) => ReturnType<InlineTaskLinkAdapter["render"]>;

type Messages = ReturnType<typeof useCommaMessages>;

/** Rows the card shows: the Tasks whose Worker it follows. */
const MAX_CARD_ROWS = MAX_FOCUS_TASK_FEEDS;

/**
 * The Tasks a reader can see: a Task without a title is still loading or not
 * readable, so the bubble neither names nor counts it, and the card skips it.
 */
export function titledTasks(focus: ActivityFocus) {
  return focus.tasks.filter((task) => task.title);
}

/** The card's name for assistive technology: its one Task, or how many. */
export function activityFocusCardLabel(messages: Messages, focus: ActivityFocus) {
  const tasks = titledTasks(focus);
  return tasks.length === 1
    ? tasks[0]!.title!
    : messages.chat_activity_card_tasks({ count: tasks.length });
}

/**
 * The Tasks behind the status bubble. Each row opens its Task and shows the
 * Worker, the title, and the Worker's latest step, which shimmers while the
 * Worker works. A row always has three single lines, so the card keeps its
 * height while steps load or change. Hovering or focusing a row shows the
 * Worker's recent steps in a log beside the card. When Tasks come or go, the
 * card eases to its new height.
 */
export function ActivityFocusCard({
  focus,
  taskLink,
}: {
  focus: ActivityFocus;
  taskLink: TaskLink;
}) {
  const messages = useCommaMessages();
  const productLease = useChatProductLease();
  const tasks = titledTasks(focus);
  const listed = tasks.slice(0, MAX_CARD_ROWS);
  const more = tasks.length - listed.length;
  const frame = useRef<HTMLDivElement>(null);
  const body = useRef<HTMLDivElement>(null);
  useEasedHeight(frame, body);

  return (
    <div
      className="comma-chat-activity-card"
      data-testid="activity-focus-card"
      ref={frame}
    >
      <div className="comma-chat-activity-card-body" ref={body}>
        {tasks.length > 1 ? (
          <strong className="comma-chat-activity-card-heading">
            {messages.chat_activity_card_tasks({ count: tasks.length })}
          </strong>
        ) : null}
        <ul className="comma-chat-activity-card-rows">
          {listed.map((task) => {
            const link = taskLink(task);
            const history =
              task.worker && productLease
                ? {
                    groupId: focus.groupId,
                    conversationId: task.conversationId,
                    participantId: task.worker.participantId,
                  }
                : undefined;
            return history ? (
              <TrackedTaskItem
                key={task.conversationId}
                task={task}
                link={link}
                history={history}
              />
            ) : (
              <li key={task.conversationId}>
                <RowLink link={link}>
                  <TaskRow task={task} />
                </RowLink>
              </li>
            );
          })}
        </ul>
        {more > 0 ? (
          <p className="comma-chat-activity-card-more">
            {messages.chat_activity_card_more({ count: more })}
          </p>
        ) : null}
      </div>
    </div>
  );
}

/**
 * Keeps `frame` at the height of `content` and lets CSS ease the change. The
 * first height is set at once; later ones transition. While the height moves,
 * `data-resizing` marks the frame so its styles may clip the content that has
 * outgrown it. `onResize` runs after each new height.
 */
function useEasedHeight(
  frame: RefObject<HTMLElement | null>,
  content: RefObject<HTMLElement | null>,
  onResize?: (height: number) => void
) {
  const resized = useRef(onResize);
  resized.current = onResize;
  useLayoutEffect(() => {
    const outer = frame.current;
    const inner = content.current;
    if (!outer || !inner || typeof ResizeObserver === "undefined") return undefined;
    let height: number | undefined;
    const settle = (event: TransitionEvent) => {
      if (event.target === outer && event.propertyName === "height")
        delete outer.dataset.resizing;
    };
    const observer = new ResizeObserver(() => {
      const next = inner.offsetHeight;
      if (next === height) return;
      if (height !== undefined) outer.dataset.resizing = "true";
      height = next;
      outer.style.height = `${next}px`;
      resized.current?.(next);
    });
    observer.observe(inner);
    outer.addEventListener("transitionend", settle);
    outer.addEventListener("transitioncancel", settle);
    return () => {
      observer.disconnect();
      outer.removeEventListener("transitionend", settle);
      outer.removeEventListener("transitioncancel", settle);
    };
  }, [frame, content]);
}

type Link = ReturnType<TaskLink>;

function RowLink({ link, children }: { link: Link; children: ReactNode }) {
  return cloneElement(link, {
    className: ["comma-chat-activity-card-row", link.props.className]
      .filter(Boolean)
      .join(" "),
    [HOVER_PANEL_ITEM]: "",
    children,
  } as Partial<typeof link.props>) as ReactElement;
}

// The log opens beside the card, on the side with room for it.
const LOG_WIDTH = 300;
// The log keeps this far from the window's top.
const LOG_MARGIN = 16;

/** A row whose Worker's Session this login reads: its latest step and its log. */
function TrackedTaskItem({
  task,
  link,
  history,
}: {
  task: ActivityFocusTask;
  link: Link;
  history: SessionHistoryInput;
}) {
  const view = useWorkerSteps(history);
  const [side, setSide] = useState<"end" | "start">("end");
  const item = useRef<HTMLLIElement>(null);
  const place = useCallback(() => {
    const box = item.current?.getBoundingClientRect();
    if (!box) return;
    const roomEnd = window.innerWidth - box.right;
    setSide(roomEnd >= LOG_WIDTH + 16 || roomEnd >= box.left ? "end" : "start");
    // The log grows up from the card's bottom and scrolls before the window's top.
    const card = item.current!.closest<HTMLElement>(".comma-chat-activity-card");
    if (card)
      item.current!.style.setProperty(
        "--comma-activity-log-room",
        `${Math.max(0, card.getBoundingClientRect().bottom - LOG_MARGIN)}px`
      );
  }, []);
  // Measured once the panel has its place, which keyboard focus may reach
  // first, and again when the pointer reaches the row.
  useEffect(() => {
    return uiClock.frame(place);
  }, [place]);
  return (
    <li className="comma-chat-activity-card-item" ref={item} onPointerEnter={place}>
      <RowLink link={link}>
        <TaskRow task={task} view={view} />
      </RowLink>
      <WorkerLog view={view} side={side} />
    </li>
  );
}

function TaskRow({
  task,
  view,
}: {
  task: ActivityFocusTask;
  view?: WorkerStepsView | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  // A part that is not known yet is a placeholder bar, never stand-in words,
  // and the row keeps its three lines while the parts load.
  const placeholder = (
    <span aria-hidden className="comma-chat-activity-card-placeholder" />
  );
  // Until a step loads, or where this login may not read the Session, the
  // third line holds the Task's status.
  const status = task.statusBucket
    ? taskStatusBucketLabel(task.statusBucket, locale)
    : placeholder;
  const shown = view?.shown;
  return (
    <>
      <span className="comma-chat-activity-card-who">
        {task.worker ? (
          <WorkerModelMark
            className="comma-chat-activity-card-avatar"
            data-worker="true"
            vendor={task.worker.vendor}
          />
        ) : (
          <span aria-hidden className="comma-chat-activity-card-avatar" />
        )}
        {task.worker ? (
          <span className="comma-chat-activity-card-meta">{task.worker.name}</span>
        ) : task.worker === null ? (
          <span className="comma-chat-activity-card-meta">
            {messages.chat_activity_card_no_worker()}
          </span>
        ) : (
          placeholder
        )}
      </span>
      <span className="comma-chat-activity-card-title">{task.title}</span>
      <span className="comma-chat-activity-card-step">
        <span className="comma-chat-activity-step-text">
          {view && shown ? (
            <StepLine step={shown} clock={view.clock} shimmer={view.working} />
          ) : (
            status
          )}
        </span>
        <ChevronRightSmallIcon
          aria-hidden
          className="comma-chat-activity-card-chevron"
        />
      </span>
    </>
  );
}

/**
 * A step's time and words. The sweep covers only the words, so it crosses
 * the text at the same pace however wide the line is.
 */
function StepLine({
  step,
  clock,
  shimmer,
}: {
  step: ShownStep;
  clock: Intl.DateTimeFormat;
  shimmer: boolean;
}) {
  return (
    <>
      {step.at === undefined ? null : <time>{clock.format(step.at)}</time>}
      <span className="comma-chat-activity-step-words">
        <span data-shimmer={shimmer ? "true" : undefined}>{step.words}</span>
      </span>
    </>
  );
}

/**
 * The Worker's recent steps beside the card, oldest first, ending with the
 * step in progress. It shows only once the Session page has steps to list.
 * It grows up to hold every step the Worker's page lists, scrolls only where
 * the window cannot hold them, and follows the newest step unless people have
 * scrolled back.
 */
function WorkerLog({ view, side }: { view: WorkerStepsView; side: "end" | "start" }) {
  const { progress } = view;
  if (!progress || (progress.steps.length === 0 && !progress.current)) return null;
  return (
    <div className="comma-chat-activity-log" data-side={side}>
      <WorkerLogSteps progress={progress} clock={view.clock} />
    </div>
  );
}

function WorkerLogSteps({
  progress,
  clock,
}: {
  progress: WorkerProgress;
  clock: Intl.DateTimeFormat;
}) {
  const messages = useCommaMessages();
  const frame = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLOListElement>(null);
  const follow = useLogFollow(frame);
  useEasedHeight(frame, list, follow.reveal);
  // The step in progress holds one last row whatever it is, so a Worker that
  // turns from thinking to a command and back changes its words in place;
  // only a finished step rises in above it.
  const items = [
    ...progress.steps.map((step) => ({ key: step.id, step, current: false })),
    ...(progress.current
      ? [{ key: CURRENT_ROW, step: progress.current, current: true }]
      : []),
  ];
  return (
    <div
      className="comma-chat-activity-log-frame"
      ref={frame}
      onScroll={follow.scrolled}
      onWheel={follow.released}
      onPointerDown={follow.released}
    >
      <ol className="comma-chat-activity-log-steps" ref={list}>
        {items.map(({ key, step, current }) => (
          <li key={key} data-failed={step.failed ? "true" : undefined}>
            <StepLine
              step={{ at: step.at, words: stepWords(messages, step, current) }}
              clock={clock}
              shimmer={current}
            />
          </li>
        ))}
      </ol>
    </div>
  );
}

/**
 * Keeps a scrolling log on its newest step. The log follows until people
 * scroll back, and follows again once they return to the end.
 */
function useLogFollow(frame: RefObject<HTMLElement | null>) {
  const following = useRef(true);
  // While the log moves itself, its scroll events are not people's.
  const moving = useRef<number | undefined>(undefined);
  const end = useCallback(
    (height: number) => {
      const box = frame.current;
      if (!box) return 0;
      const shown = Math.min(
        height,
        Number.parseFloat(getComputedStyle(box).maxHeight) || height
      );
      return Math.max(0, height - shown);
    },
    [frame]
  );
  return useMemo(
    () => ({
      reveal(height: number) {
        const box = frame.current;
        if (!box || !following.current) return;
        const top = end(height);
        if (Math.abs(box.scrollTop - top) < 1) return;
        moving.current = top;
        box.scrollTo({
          top,
          behavior: box.scrollTop === 0 && top === 0 ? "instant" : "smooth",
        });
      },
      scrolled() {
        const box = frame.current;
        if (!box) return;
        if (moving.current !== undefined) {
          if (Math.abs(box.scrollTop - moving.current) < 1) moving.current = undefined;
          return;
        }
        following.current = box.scrollTop + box.clientHeight >= box.scrollHeight - 2;
      },
      released() {
        moving.current = undefined;
      },
    }),
    [end, frame]
  );
}

/** The key of the log's last row, the step in progress, whichever it is. */
const CURRENT_ROW = "current";
