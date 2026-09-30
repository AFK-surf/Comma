import { LoadingIndicator } from "@comma/ui";
import { memo, useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  Button,
  CommaLogoAnimation,
  HoverCard,
  ScrollArea,
  ScrollAreaLoadMore,
} from "@comma/ui";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type {
  SessionHistoryInput,
  SessionHistoryRecord,
} from "../../../runtime-chat/sessionHistoryBridge";
import { useSessionHistory } from "../../../runtime-chat/sessionHistoryBridge";
import { useChatRegistry, useChatProductLease } from "../ChatProvider";
import type { ChatParticipantStatus } from "../model/conversationChannel";
import { workerMeshGradientStyle } from "../thread/activity/workerAvatar";
import {
  formatSessionDuration,
  presentSessionRecords,
  type SessionItemLabels,
  type SessionItemPresentation,
  type SessionPresentationCache,
} from "./model/sessionHistoryPresentation";
import { SessionHistoryTimeline } from "./timeline/SessionHistoryTimeline";
import { SessionHistoryMiniTimeline } from "./timeline/SessionHistoryMiniTimeline";
import { SessionJson } from "./SessionJson";
import { useHistoryRecords } from "./model/sessionHistoryLive";
import { useSessionHistoryClock } from "./timeline/sessionHistoryClock";
import { useSessionToolLabel } from "./model/sessionHistoryToolLabel";
import { SessionModelMetrics } from "./SessionModelMetrics";
import { useCommaClientSettings } from "../../commaClientSettings";
import {
  SessionOperationContext,
  useSessionOperation,
} from "./SessionOperationContext";
import {
  sameSessionHistoryEntry,
  sessionHistoryEntries,
  sessionRecordStartTime,
  type SessionHistoryEntry,
} from "./model/sessionHistoryEntries";

function usePresentedRecords(records: readonly SessionHistoryRecord[] | undefined) {
  const m = useCommaMessages();
  // Items depend on the labels, so each labels object gets its own cache.
  // Unchanged records keep their items: a snapshot that appends one record
  // must not present the whole loaded window again.
  const { labels, cache } = useMemo<{
    labels: SessionItemLabels;
    cache: SessionPresentationCache;
  }>(
    () => ({
      cache: new WeakMap(),
      labels: {
        input: m.session_item_input(),
        model: m.session_item_model(),
        thinking: m.session_item_thinking(),
        call: m.session_item_call(),
        result: m.session_item_result(),
        running: m.session_item_running(),
        success: m.session_item_success(),
        error: m.session_item_error(),
        cancelled: m.session_item_cancelled(),
        context: m.session_item_context(),
        migration: m.session_item_migration(),
        runtime: m.session_item_runtime(),
        unknown: m.session_item_unknown(),
        empty: m.session_item_empty(),
        source: m.session_item_source(),
        locationRequested: m.session_location_requested(),
        inputSource: (source) => {
          const provider = source?.provider;
          if (!provider) return m.session_source_unknown();
          const actor =
            source.actor_type &&
            {
              agent: m.session_source_agent(),
              system: m.session_source_system(),
              user: "Comma",
            }[source.actor_type];
          const name = {
            internal: actor || m.session_source_internal(),
            telegram: "Telegram",
            slack: "Slack",
            feishu: "Feishu",
            wechat: "WeChat",
            imessage: "iMessage",
            voice: m.session_source_voice(),
            signal: "Signal",
          }[provider];
          const conversation =
            source.conversation_kind &&
            {
              agent_task: m.session_source_task(),
              user_chat: m.session_source_chat(),
            }[source.conversation_kind];
          const chat =
            source.chat_type &&
            {
              private: m.session_source_private(),
              group: m.session_source_group(),
              supergroup: m.session_source_group(),
              channel: m.session_source_channel(),
            }[source.chat_type];
          const detail = conversation || chat;
          return [name, detail].filter(Boolean).join(" · ");
        },
        sent: m.session_item_sent(),
        structured: m.session_item_structured(),
        count: (name, count) =>
          (
            ({
              messages: m.session_item_messages,
              tasks: m.session_item_tasks,
              matches: m.session_item_matches,
              files: m.session_item_files,
              items: m.session_item_items,
            })[name] ?? m.session_item_items
          )({ count }),
      },
    }),
    [m]
  );
  return useMemo(
    () => presentSessionRecords(records ?? [], labels, cache),
    [records, labels, cache]
  );
}

export function ConversationParticipants({
  groupId,
  participants,
  onOpen,
}: {
  groupId: string;
  participants: ChatParticipantStatus[];
  onOpen(participant: ChatParticipantStatus): void;
}) {
  const productLease = useChatProductLease();
  const { settings } = useCommaClientSettings();
  if (!productLease || !settings.sessionHistoryEnabled) return null;
  return (
    <div className="comma-session-participants">
      {participants.map((participant) => (
        <ParticipantHistoryLink
          key={participant.participantId}
          participant={participant}
          onOpen={() => onOpen(participant)}
          input={{
            session: productLease,
            groupId,
            conversationId: participant.conversationId,
            participantId: participant.participantId,
          }}
        />
      ))}
    </div>
  );
}

function ParticipantHistoryLink({
  participant,
  input,
  onOpen,
}: {
  participant: ChatParticipantStatus;
  input: SessionHistoryInput;
  onOpen(): void;
}) {
  const [hovered, setHovered] = useState(false);
  const messages = useCommaMessages();
  const name =
    participant.name?.replace(/^Default workspace\s+/i, "").trim() ||
    messages.chat_actor_router();
  const router = participant.actorRole !== "worker";
  return (
    <HoverCard
      className="comma-session-hover"
      onOpenChange={setHovered}
      content={hovered ? <SessionHistoryPreview input={input} name={name} /> : null}
    >
      <button
        type="button"
        className="comma-session-participant"
        onClick={onOpen}
        aria-label={messages.session_history_open({ name })}
        data-testid="session-history-participant"
      >
        <span
          aria-hidden
          className="comma-session-avatar"
          style={
            router
              ? undefined
              : workerMeshGradientStyle(
                  participant.actorId ?? participant.participantId
                )
          }
        >
          {router ? <CommaLogoAnimation /> : null}
        </span>
        <span>{name}</span>
        <span
          className="comma-session-participant-state"
          data-state={participant.state}
          aria-hidden
        />
      </button>
    </HoverCard>
  );
}

function SessionHistoryPreview({
  input,
  name,
}: {
  input: SessionHistoryInput;
  name: string;
}) {
  const { snapshot, transportError } = useSessionHistory(input, "preview");
  const messages = useCommaMessages();
  const records = useHistoryRecords(snapshot);
  const presentations = usePresentedRecords(records);
  const recentRecords = useHistoryRecords(snapshot, true);
  const recentPresentations = usePresentedRecords(recentRecords);
  const locale = useCommaLocale();
  const entries = sessionHistoryEntries(records ?? [], presentations);
  return (
    <SessionOperationContext
      groupId={input.groupId}
      conversationId={input.conversationId}
    >
      <div data-testid="session-history-preview">
        <div className="comma-session-preview-heading">
          <strong>{name}</strong>
          <span>{messages.session_history_title()}</span>
        </div>
        {(!snapshot || snapshot.status === "loading") && !records.length ? (
          <p>
            <LoadingIndicator label={messages.session_history_loading()} />
          </p>
        ) : (snapshot?.error || transportError) && !records.length ? (
          <p>{messages.session_history_failed()}</p>
        ) : records.length === 0 ? (
          <p>{messages.session_history_empty()}</p>
        ) : (
          <>
            <SessionHistoryMiniTimeline
              records={recentRecords}
              items={recentPresentations}
              clockOffsetMs={snapshot?.clockOffsetMs ?? 0}
            />
            <ol>
              {entries.slice(-3).map((entry) => (
                <li
                  key={entry.id}
                  data-kind={
                    !entry.tool && entry.record.kind === "assistant"
                      ? "model"
                      : entry.item.kind
                  }
                  className="comma-session-preview-row"
                >
                  <SessionRecordSummary
                    entry={entry}
                    locale={locale}
                    clockOffsetMs={snapshot?.clockOffsetMs ?? 0}
                  />
                </li>
              ))}
            </ol>
          </>
        )}
        <span className="comma-session-hint">
          {messages.session_history_view_all()}
        </span>
      </div>
    </SessionOperationContext>
  );
}

/** A row and its offset from the top of the scrolled content. Scrolling moves
 * the viewport, not the row, so this offset changes only when content above the
 * row changes — the browser reports a scroll one frame later, and the ledger
 * re-renders in between must not treat the pending scroll as content growth. */
type SessionScrollAnchor = { row: HTMLElement; top: number };

function readSessionScrollAnchor(viewport: HTMLElement): SessionScrollAnchor | null {
  const rows = viewport.querySelectorAll<HTMLElement>("article[data-record-id]");
  const top = viewport.getBoundingClientRect().top;
  // The loaded ledger is bounded by explicit pages. Binary search avoids a
  // geometry read for every row on each scroll in a large loaded window.
  let from = 0;
  let to = rows.length;
  while (from < to) {
    const middle = Math.floor((from + to) / 2);
    if (rows[middle]!.getBoundingClientRect().bottom <= top) from = middle + 1;
    else to = middle;
  }
  const row = rows[from];
  return row
    ? { row, top: row.getBoundingClientRect().top - top + viewport.scrollTop }
    : null;
}

export function SessionHistoryPage({
  groupId,
  participant,
  active = true,
}: {
  groupId: string;
  participant: Pick<ChatParticipantStatus, "conversationId" | "participantId" | "name">;
  active?: boolean;
}) {
  const { productLease } = useChatRegistry();
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const { snapshot, transportError, load } = useSessionHistory(
    {
      session: productLease,
      groupId,
      conversationId: participant.conversationId,
      participantId: participant.participantId,
    },
    "latest"
  );
  const viewport = useRef<HTMLDivElement>(null);
  const initialPositioned = useRef(false);
  const followingLatest = useRef(true);
  const lastScrollTop = useRef(0);
  const scrollAnchor = useRef<SessionScrollAnchor | null>(null);
  const records = useHistoryRecords(snapshot);
  const presentations = usePresentedRecords(records);
  const entries = useMemo(
    () => sessionHistoryEntries(records ?? [], presentations),
    [records, presentations]
  );
  const [selected, setSelected] = useState<string>();
  const [focusedIds, setFocusedIds] = useState<ReadonlySet<string>>();
  const selectRecord = useCallback(
    (id: string) => {
      const entryId =
        entries.find((entry) => entry.id === id || entry.recordIds.includes(id))?.id ??
        id;
      setSelected(entryId);
      followingLatest.current = false;
      const element = Array.from(
        viewport.current?.querySelectorAll<HTMLElement>("[data-record-id]") ?? []
      ).find((row) => row.dataset.recordId === entryId);
      element?.scrollIntoView({ block: "center" });
      if (viewport.current)
        scrollAnchor.current = readSessionScrollAnchor(viewport.current);
    },
    [entries]
  );
  const restorePosition = useCallback(() => {
    const element = viewport.current;
    // Loading temporarily changes the page header height. Keep the pre-load
    // anchor until settlement instead of replacing it with a clamped position.
    if (
      !active ||
      !initialPositioned.current ||
      !element ||
      snapshot?.status === "loading"
    )
      return;
    const anchor = scrollAnchor.current;
    if (followingLatest.current) {
      element.scrollTop = element.scrollHeight;
    } else if (anchor && element.contains(anchor.row)) {
      element.scrollTop +=
        anchor.row.getBoundingClientRect().top -
        element.getBoundingClientRect().top +
        element.scrollTop -
        anchor.top;
    }
    lastScrollTop.current = element.scrollTop;
    scrollAnchor.current = readSessionScrollAnchor(element);
  }, [active, snapshot?.status]);
  // Source updates can add rows; the ScrollArea resize callback also preserves
  // the anchor when a live duration line first becomes visible.
  useLayoutEffect(() => {
    const element = viewport.current;
    if (
      !active ||
      !element ||
      snapshot?.loaded !== "detail" ||
      snapshot.status !== "ready"
    )
      return;
    if (!initialPositioned.current) {
      element.scrollTop = element.scrollHeight;
      initialPositioned.current = true;
    }
    restorePosition();
  }, [active, entries, snapshot?.loaded, snapshot?.status, restorePosition]);
  const loadOlder = () => {
    if (!snapshot?.hasMore || snapshot.status === "loading") return;
    followingLatest.current = false;
    if (viewport.current)
      scrollAnchor.current = readSessionScrollAnchor(viewport.current);
    load("older");
  };
  return (
    <SessionOperationContext
      groupId={groupId}
      conversationId={participant.conversationId}
    >
      <section
        className="comma-session-history"
        aria-label={messages.session_history_title()}
        data-testid="session-history-page"
      >
        <SessionHistoryTimeline
          active={active}
          records={records ?? []}
          clockOffsetMs={snapshot?.clockOffsetMs ?? 0}
          items={presentations}
          selected={selected}
          onSelect={selectRecord}
          onRange={setFocusedIds}
        />
        <div className="comma-session-ledger-heading" aria-hidden>
          <span>{messages.session_timeline_event()}</span>
          <span>{messages.session_timeline_summary()}</span>
          <span>{messages.session_timeline_timing()}</span>
        </div>
        <ScrollArea
          ref={viewport}
          className="comma-session-scroll"
          edgeEffect="none"
          onScroll={(event) => {
            const element = event.currentTarget;
            // A queued follow scroll can arrive after the live row grows.
            // Only movement toward older records stops an existing follow.
            followingLatest.current = followingLatest.current
              ? element.scrollTop >= lastScrollTop.current
              : element.scrollHeight - element.clientHeight - element.scrollTop <= 4;
            lastScrollTop.current = element.scrollTop;
            scrollAnchor.current = readSessionScrollAnchor(element);
          }}
          onContentResize={restorePosition}
          onViewportResize={restorePosition}
          viewportProps={{
            "aria-label": messages.session_history_records(),
            role: "region",
            tabIndex: 0,
            style: { overflowAnchor: "none" },
          }}
        >
          <div className="comma-session-timeline">
            <div className="comma-session-page-state">
              {snapshot?.status === "loading" || (!snapshot && !transportError) ? (
                <output>
                  <LoadingIndicator label={messages.session_history_loading()} />
                </output>
              ) : snapshot?.error || transportError ? (
                <>
                  <p role="alert">
                    {snapshot?.error === "forbidden"
                      ? messages.session_history_forbidden()
                      : messages.session_history_failed()}
                  </p>
                  <Button
                    hierarchy="secondary-gray"
                    size="sm"
                    onPress={() =>
                      snapshot?.loaded === "detail" ? loadOlder() : load("latest")
                    }
                  >
                    {messages.session_history_retry()}
                  </Button>
                </>
              ) : snapshot?.hasMore ? (
                // Older records load as the reader scrolls up to them; the
                // anchor loadOlder takes keeps the rows in view where they are.
                <ScrollAreaLoadMore
                  edge="start"
                  hasMore={active}
                  onLoadMore={loadOlder}
                />
              ) : (
                <p>
                  {records?.length
                    ? messages.session_history_start()
                    : messages.session_history_empty()}
                </p>
              )}
            </div>
            {entries.map((entry) => (
              <SessionRecord
                active={active && entry.record.execution?.live === true}
                key={entry.id}
                entry={entry}
                locale={locale}
                // Only live rows read the clock anchor. Each reconnect moves it
                // and must not re-render every completed row.
                clockOffsetMs={
                  entry.record.execution?.live ? (snapshot?.clockOffsetMs ?? 0) : 0
                }
                selected={selected === entry.id}
                outside={
                  focusedIds !== undefined &&
                  !focusedIds.has(entry.id) &&
                  !entry.recordIds.some((id) => focusedIds.has(id))
                }
                onSelect={setSelected}
              />
            ))}
          </div>
        </ScrollArea>
      </section>
    </SessionOperationContext>
  );
}

type SessionRecordProps = {
  active: boolean;
  entry: SessionHistoryEntry;
  locale: string;
  clockOffsetMs: number;
  selected: boolean;
  outside: boolean;
  onSelect(id: string): void;
};
// Hosts deliver each snapshot as a structured clone, so entries are rebuilt as
// new objects even when their records did not change. Compare them by content.
const sameSessionRecordProps = (
  previous: SessionRecordProps,
  next: SessionRecordProps
) =>
  (Object.keys(next) as (keyof SessionRecordProps)[]).every((key) =>
    key === "entry"
      ? sameSessionHistoryEntry(previous.entry, next.entry)
      : Object.is(previous[key], next[key])
  );
const SessionRecord = memo(function SessionRecord({
  active,
  entry,
  locale,
  clockOffsetMs,
  selected,
  outside,
  onSelect,
}: SessionRecordProps) {
  const messages = useCommaMessages();
  const toolLabel = useSessionToolLabel();
  const { record, item } = entry;
  const label =
    entry.tool && record.kind === "assistant"
      ? messages.session_item_call()
      : item.label;
  const [expanded, setExpanded] = useState(false);
  return (
    <article
      className="comma-session-record"
      data-record-id={entry.id}
      data-kind={!entry.tool && record.kind === "assistant" ? "model" : item.kind}
      data-selected={selected}
      data-timeline-outside={outside}
    >
      <details onToggle={(event) => setExpanded(event.currentTarget.open)}>
        <summary
          onClick={() => onSelect(entry.id)}
          aria-label={`${item.action || item.tools.map(toolLabel).join(" · ") || label} · ${messages.session_item_debug()}`}
        >
          <SessionRecordSummary
            active={active}
            entry={entry}
            locale={locale}
            clockOffsetMs={clockOffsetMs}
          />
        </summary>
        {expanded && (
          <div className="comma-session-debug">
            <strong>{messages.session_item_debug()}</strong>
            <p>{item.summary}</p>
            <SessionDebugRecords records={entry.debugRecords} />
          </div>
        )}
      </details>
    </article>
  );
}, sameSessionRecordProps);
function SessionRecordSummary({
  active = true,
  entry,
  locale,
  clockOffsetMs,
}: {
  active?: boolean;
  entry: SessionHistoryEntry;
  locale: string;
  clockOffsetMs: number;
}) {
  const messages = useCommaMessages();
  const toolLabel = useSessionToolLabel();
  const { record, item } = entry;
  const executionTime = sessionRecordStartTime(record);
  const label =
    entry.tool && record.kind === "assistant"
      ? messages.session_item_call()
      : item.label;
  const action = item.action || item.tools.map(toolLabel).join(" · ") || label;
  const summary =
    item.operation ||
    (item.summary !== action &&
    item.summary !== label &&
    item.summary !== messages.session_item_empty()
      ? item.summary
      : "");
  return (
    <>
      <strong
        className="comma-session-kind"
        title={item.tools.join(" · ") || undefined}
      >
        <span>{action}</span>
      </strong>
      <span className="comma-session-row-content">
        {!entry.tool &&
          (record.kind === "assistant" || record.execution?.lane === "model") && (
            <SessionModelMetrics record={record} />
          )}
        <span className="comma-session-summary">
          {item.destination ? (
            <SessionRecordDestination item={item} fallback={summary} />
          ) : (
            summary
          )}
        </span>
        {item.source && (
          <span className="comma-session-operation-result">{item.source}</span>
        )}
        {item.tools.length > 0 &&
          ["running", "success", "error", "cancelled"].includes(item.kind) && (
            <span className="comma-session-operation-result">
              <span className="comma-session-operation-status">{label}</span>
              {item.operation &&
                item.summary !== item.operation &&
                item.summary !== label && <span>{item.summary}</span>}
            </span>
          )}
      </span>
      <span
        className="comma-session-meta"
        title={formatRecordTime(executionTime, locale)}
      >
        <time>{formatRecordTime(executionTime, locale, true)}</time>
        {!(entry.tool && record.kind === "assistant") && (
          <SessionRecordDuration
            active={active}
            record={record}
            duration={item.duration}
            clockOffsetMs={clockOffsetMs}
          />
        )}
      </span>
    </>
  );
}

// Only rows that reference another conversation need its changing display name.
// Keep that context subscription in the text leaf; the row's timestamp and debug
// content do not depend on a retained conversation title.
function SessionRecordDestination({
  item,
  fallback,
}: {
  item: SessionItemPresentation;
  fallback: string | false;
}) {
  return useSessionOperation(item) || fallback;
}

function SessionRecordDuration({
  active,
  record,
  duration,
  clockOffsetMs,
}: {
  active: boolean;
  record: SessionHistoryRecord;
  duration: number | undefined;
  clockOffsetMs: number;
}) {
  const live = record.execution?.live === true;
  const now = useSessionHistoryClock(active && live);
  const label = formatSessionDuration(
    live
      ? Math.max(record.execution!.observed_at_ms, now + clockOffsetMs) -
          record.execution!.started_at_ms
      : duration
  );
  return label ? <span className="comma-session-duration">{label}</span> : null;
}

function SessionDebugRecords({ records }: { records: SessionHistoryRecord[] }) {
  const items = usePresentedRecords(records);
  const m = useCommaMessages();
  if (records.length === 1) return <SessionJson value={records[0]} />;
  return (
    <div className="comma-session-debug-stages">
      {records.map((record, index) => (
        <SessionDebugStage
          key={record.id}
          record={record}
          label={
            record.kind === "assistant" ? m.session_item_call() : items[index]!.label
          }
        />
      ))}
    </div>
  );
}
function SessionDebugStage({
  record,
  label,
}: {
  record: SessionHistoryRecord;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <details
      className="comma-session-debug-stage"
      data-source-id={record.id}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>
        #{record.id} · {label}
      </summary>
      {open && <SessionJson value={record} />}
    </details>
  );
}
function formatRecordTime(value: number | null, locale: string, short = false) {
  if (value == null) return "";
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? ""
    : short
      ? date.toLocaleTimeString(locale, { hour12: false })
      : date.toLocaleString(locale);
}
