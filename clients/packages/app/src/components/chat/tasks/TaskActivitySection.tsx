import type {
  ChatTaskActivity,
  ChatTaskActivityEntry,
  ChatTaskActivityGroup,
} from "@comma/chat-contract";
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  ChatBubbleIcon,
  CircleCheckFilledIcon,
  CirclePlusIcon,
  InfinityIcon,
  LoaderIcon,
  MoreHorizontalIcon,
} from "@comma/ui/components/icons";
import { memo, useEffect, useId, useState, type ReactNode } from "react";
import { normalizeUnixTimestampMs } from "../../search/normalizeUnixTimestampMs";
import { useTimeLabel } from "../../tasks/useTimeLabel";

/** More groups than this fold all but the oldest one and the latest two. */
const GROUP_FOLD = { above: 4, head: 1, tail: 2 };
/** More milestones in one group than this fold all but the first two and the latest three. */
const ENTRY_FOLD = { above: 8, head: 2, tail: 3 };

/**
 * The Task's milestones as a timeline, read-only, after Linear's activity log:
 * each request (the Task's creation, a person's later message, or a Loop run)
 * on one line through the requests, the milestones recorded after it nested
 * below. Pressing a request shows or hides its milestones; pressing a
 * milestone shows its message in the Task chat, and without a chat it is
 * text. A row names the day only when it differs from the row above. While
 * the Task's Agent works, the last request ends with a live row. A long log
 * keeps its start and its latest rows; a fold row stands for the rest until
 * pressed. While the Task's earlier history is not read yet, the first row
 * says so: it reads, or a press reads it.
 */
export const TaskActivitySection = memo(function TaskActivitySection({
  activity,
  onReadEarlier,
  onRevealStep,
  working = false,
}: {
  activity: ChatTaskActivity;
  /** Reads the Task's history before what the chat holds, for the Activity. */
  onReadEarlier?: (() => void) | undefined;
  onRevealStep?: ((messageId: string) => void) | undefined;
  working?: boolean | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const time = useTimeLabel();
  const entriesId = useId();
  const [allGroups, setAllGroups] = useState(false);
  const [openGroups, setOpenGroups] = useState<ReadonlySet<string>>(() => new Set());
  const [collapsedGroups, setCollapsedGroups] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  // The first row a fold row gave way to takes its focus.
  const [focusKey, setFocusKey] = useState<string>();
  useEffect(() => {
    if (focusKey !== undefined) setFocusKey(undefined);
  }, [focusKey]);

  const counted = (count: number) => ({
    count,
    formattedCount: formatNumber(count, locale),
  });
  // Rows are built top to bottom, so each knows the day the row above named.
  let shownDay: string | undefined;
  const when = (at: number | undefined) => {
    const ms = normalizeUnixTimestampMs(at);
    if (ms === undefined) return null;
    const day = new Date(ms).toDateString();
    const date = shownDay === undefined ? undefined : day !== shownDay;
    shownDay = day;
    return (
      <>
        <time
          className="comma-task-activity-time"
          dateTime={new Date(ms).toISOString()}
        >
          {time(ms, date)}
        </time>
      </>
    );
  };
  const row = (messageId: string | undefined, content: ReactNode, key: string) => {
    const ref = key === focusKey ? focusOnMount : undefined;
    return onRevealStep && messageId ? (
      <button
        className="comma-task-activity-row"
        data-no-press-feedback
        onClick={() => onRevealStep(messageId)}
        ref={ref}
        type="button"
      >
        {content}
      </button>
    ) : (
      <div
        className="comma-task-activity-row"
        ref={ref}
        {...(ref ? { tabIndex: -1 } : {})}
      >
        {content}
      </div>
    );
  };
  const requestLabel = (request: NonNullable<ChatTaskActivityGroup["request"]>) =>
    request.kind === "brief"
      ? messages.task_activity_created()
      : request.kind === "run"
        ? messages.task_activity_run()
        : request.text;

  const entryItem = (entry: ChatTaskActivityEntry, key: string) => (
    <li className="comma-task-activity-item" data-testid="task-activity-step" key={key}>
      {row(
        entry.messageId,
        <>
          <span
            aria-hidden
            className="comma-task-activity-icon comma-icon-slot"
            data-done="true"
          >
            <CircleCheckFilledIcon />
          </span>
          <span className="comma-task-activity-text">
            <span className="comma-task-activity-title">{entry.title}</span>
            {when(entry.at)}
          </span>
        </>,
        key
      )}
    </li>
  );

  const groupItem = (group: ChatTaskActivityGroup, index: number, last: boolean) => {
    const key = groupKey(group, index);
    const { request } = group;
    const live = last && working;
    const collapsible = group.entries.length > 0 || live;
    const collapsed = collapsible && collapsedGroups.has(key);
    const listId = `${entriesId}-${index}`;
    // The request row comes first, so it names the day before its milestones.
    const content = request ? (
      <>
        <span aria-hidden className="comma-task-activity-icon comma-icon-slot">
          {requestIcon(request.kind)}
        </span>
        <span className="comma-task-activity-text" data-kind="request">
          <span className="comma-task-activity-title">{requestLabel(request)}</span>
          {when(request.at)}
        </span>
      </>
    ) : null;
    const head =
      content && collapsible ? (
        <button
          {...(collapsed ? {} : { "aria-controls": listId })}
          aria-expanded={!collapsed}
          className="comma-task-activity-row"
          data-no-press-feedback
          data-testid="task-activity-request"
          onClick={() =>
            setCollapsedGroups((current) => {
              const next = new Set(current);
              if (!next.delete(key)) next.add(key);
              return next;
            })
          }
          ref={key === focusKey ? focusOnMount : undefined}
          type="button"
        >
          {content}
        </button>
      ) : content ? (
        row(undefined, content, key)
      ) : null;
    if (collapsed)
      return (
        <li
          className="comma-task-activity-group"
          data-testid="task-activity-group"
          key={key}
        >
          {head}
        </li>
      );
    const entryKey = (entryIndex: number) => `${key}#${entryIndex}`;
    const fold = openGroups.has(key) ? undefined : folded(group.entries, ENTRY_FOLD);
    const entries = fold
      ? [
          ...fold.head.map((entry, at) => entryItem(entry, entryKey(at))),
          foldRow(
            "comma-task-activity-item",
            "task-activity-more-steps",
            messages.task_activity_more_steps(counted(fold.hidden)),
            () => {
              setOpenGroups((open) => new Set(open).add(key));
              setFocusKey(entryKey(fold.head.length));
            }
          ),
          ...fold.tail.map((entry, at) =>
            entryItem(entry, entryKey(group.entries.length - fold.tail.length + at))
          ),
        ]
      : group.entries.map((entry, at) => entryItem(entry, entryKey(at)));
    return (
      <li
        className="comma-task-activity-group"
        data-testid="task-activity-group"
        key={key}
      >
        {head}
        <ol className="comma-task-activity-entries" id={listId}>
          {entries}
          {live ? (
            <li className="comma-task-activity-item" data-live="true">
              <div className="comma-task-activity-row">
                <span aria-hidden className="comma-task-activity-icon comma-icon-slot">
                  <LoaderIcon />
                </span>
                <span className="comma-task-activity-text">
                  {messages.task_activity_working()}
                </span>
              </div>
            </li>
          ) : null}
        </ol>
      </li>
    );
  };

  const { earlier, groups } = activity;
  const earlierRow =
    earlier === "reading" ? (
      <li className="comma-task-activity-group" data-testid="task-activity-earlier">
        <div className="comma-task-activity-row">
          <span aria-hidden className="comma-task-activity-icon comma-icon-slot">
            <LoaderIcon />
          </span>
          <span className="comma-task-activity-text">
            {messages.task_activity_reading_earlier()}
          </span>
        </div>
      </li>
    ) : earlier === "unread" && onReadEarlier ? (
      foldRow(
        "comma-task-activity-group",
        "task-activity-earlier",
        messages.task_activity_read_earlier(),
        onReadEarlier
      )
    ) : null;
  const fold = allGroups ? undefined : folded(groups, GROUP_FOLD);
  const lastIndex = groups.length - 1;
  const tailStart = groups.length - (fold?.tail.length ?? 0);
  return (
    <section className="comma-task-panel-section" data-testid="task-panel-activity">
      <h2 className="comma-task-panel-heading">{messages.task_panel_activity()}</h2>
      <ol className="comma-task-activity">
        {earlierRow}
        {fold
          ? [
              ...fold.head.map((group, at) => groupItem(group, at, false)),
              foldRow(
                "comma-task-activity-group",
                "task-activity-more-groups",
                <>
                  {messages.task_activity_earlier_groups(counted(fold.hidden))}
                  <span className="comma-task-activity-time">
                    {messages.task_activity_steps(
                      counted(
                        groups
                          .slice(fold.head.length, tailStart)
                          .reduce((sum, group) => sum + group.entries.length, 0)
                      )
                    )}
                  </span>
                </>,
                () => {
                  setAllGroups(true);
                  setFocusKey(groupKey(groups[fold.head.length]!, fold.head.length));
                }
              ),
              ...fold.tail.map((group, at) =>
                groupItem(group, tailStart + at, tailStart + at === lastIndex)
              ),
            ]
          : groups.map((group, index) => groupItem(group, index, index === lastIndex))}
      </ol>
    </section>
  );
});

/** The items around a fold, once a list grows past `above`: its first `head`, how many it hides, its last `tail`. */
function folded<T>(
  items: readonly T[],
  { above, head, tail }: { above: number; head: number; tail: number }
) {
  if (items.length <= above) return undefined;
  return {
    head: items.slice(0, head),
    hidden: items.length - head - tail,
    tail: items.slice(items.length - tail),
  };
}

/** A group's React key and fold identity: its request message, or a run's wake time, which stays while it shows none. */
function groupKey(group: ChatTaskActivityGroup, index: number) {
  const { request } = group;
  if (!request) return `group:${index}`;
  if (request.kind === "run") return `run:${request.at ?? index}`;
  return request.messageId ?? `${request.kind}:${index}`;
}

function focusOnMount(node: HTMLElement | null) {
  node?.focus();
}

/** The row that stands for folded rows until pressed. */
function foldRow(
  className: string,
  testId: string,
  label: ReactNode,
  onPress: () => void
) {
  return (
    <li className={className} data-fold="true" data-testid={testId} key="fold">
      <button
        className="comma-task-activity-row"
        data-no-press-feedback
        onClick={onPress}
        type="button"
      >
        <span aria-hidden className="comma-task-activity-icon comma-icon-slot">
          <MoreHorizontalIcon />
        </span>
        <span className="comma-task-activity-text">{label}</span>
      </button>
    </li>
  );
}

function requestIcon(kind: NonNullable<ChatTaskActivityGroup["request"]>["kind"]) {
  if (kind === "brief") return <CirclePlusIcon />;
  if (kind === "run") return <InfinityIcon />;
  return <ChatBubbleIcon />;
}
