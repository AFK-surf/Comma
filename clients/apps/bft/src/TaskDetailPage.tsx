import { Dropdown } from "@comma/ui/components/dropdown";
import { ScrollArea, ScrollAreaLoadMore } from "@comma/ui/components/scroll-area";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type RefObject,
} from "react";
import {
  BftApiError,
  taskScheduleIntervalUnits,
  type BftSwarmTaskDetail,
  type BftTaskHeader,
  type BftTaskMessage,
  type BftTaskSchedule,
  type BftTaskScheduleForm,
  type BftTaskScheduleReply,
} from "./api";
import { writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatDateTime, formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { State } from "./ProjectOverviewPage";
import { useApi, useLastReady, useStateFor, type Resource } from "./resource";
import { spaLinkClick } from "./router";
import {
  FormDialog,
  TextAreaField,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { ErrorState, Skeleton, StaleNotice } from "./states";
import { kindLabel } from "./SwarmTasksPage";
import { appendNewer, prependOlder, startThread, type Thread } from "./taskThread";

const t = messages.taskDetail;

/*
 * Live updates poll the thread with the id of the newest message held. One
 * request at a time, only while the tab is visible: every 3 s while messages
 * arrive, doubling up to 30 s while nothing changes. A completed, failed or
 * cancelled task is followed only for two minutes after a send or a new
 * message, then not at all. Each poll is one Salix read; an open task tab
 * costs at most one request per 3 s.
 */
export const pollIntervalMs = 3_000;
export const pollMaxIntervalMs = 30_000;
export const pollLingerMs = 120_000;
/*
 * A cursor message that left the conversation reads as "nothing newer"
 * forever. After this many empty polls in a row, one poll reads the latest
 * page instead and starts the thread over if the cursor is not in it.
 */
export const cursorCheckAfter = 10;

/** The next wait: back to the start after a change, otherwise doubled. */
export const nextPollDelay = (delay: number, changed: boolean) =>
  changed ? pollIntervalMs : Math.min(delay * 2, pollMaxIntervalMs);

const draftKey = (org: string, project: string, task: string) =>
  `bft:task-draft:${org}:${project}:${task}`;

function readDraft(key: string) {
  try {
    return window.sessionStorage.getItem(key) ?? "";
  } catch {
    return "";
  }
}

function writeDraft(key: string, text: string) {
  try {
    if (text) window.sessionStorage.setItem(key, text);
    else window.sessionStorage.removeItem(key);
  } catch {
    // Storage is unavailable: the draft lives as long as the page.
  }
}

function newRequestId() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export const taskTitle = (task: Pick<BftTaskHeader, "title">) =>
  task.title ?? t.untitled;

/**
 * One task: its conversation with a steering composer, and a rail with the
 * task's schedule and participants. The conversation follows new messages by
 * polling while the tab is visible; scrolling up pages in older ones.
 */
export function TaskDetailPage({
  org,
  project,
  task,
  first,
  onRetry,
  onRefresh,
}: {
  org: string;
  project: string;
  task: string;
  first: Resource<BftSwarmTaskDetail>;
  onRetry: () => void;
  onRefresh: () => void;
}) {
  const { data, resource, stale } = useLastReady(first);
  const tasksHref = projectHref(org, project, "/tasks");
  const crumb = (
    <div className="bft-crumb">
      <a className="bft-link" href={tasksHref} onClick={spaLinkClick}>
        {t.crumb}
      </a>
    </div>
  );

  if (!data) {
    return (
      <div className="bft-page">
        <div className="bft-page-header">
          <div className="bft-page-heading">
            {crumb}
            <h1>
              <Skeleton height={22} width={260} />
            </h1>
          </div>
        </div>
        {resource.state === "error" ? (
          resource.error instanceof BftApiError &&
          resource.error.code === "runtime_unavailable" ? (
            <output className="bft-quiet-row">
              <p className="bft-quiet bft-quiet-inline">{resource.error.message}</p>
              <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
                {messages.states.retry}
              </button>
            </output>
          ) : (
            <div className="bft-panel bft-panel-fill">
              <ErrorState onRetry={onRetry} />
            </div>
          )
        ) : (
          <div className="bft-panel bft-panel-fill">
            <div className="bft-rows-skeleton">
              {Array.from({ length: 4 }, (_, index) => (
                <Skeleton height={14} key={index} />
              ))}
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <LoadedTask
      crumb={crumb}
      data={data}
      onRefresh={onRefresh}
      onRetry={onRetry}
      org={org}
      project={project}
      stale={stale}
      task={task}
      tasksHref={tasksHref}
    />
  );
}

function LoadedTask({
  org,
  project,
  task,
  data,
  stale,
  crumb,
  tasksHref,
  onRetry,
  onRefresh,
}: {
  org: string;
  project: string;
  task: string;
  data: BftSwarmTaskDetail;
  stale: boolean;
  crumb: ReactNode;
  tasksHref: string;
  onRetry: () => void;
  onRefresh: () => void;
}) {
  const api = useApi();
  const initialThread = useMemo(
    () => startThread(data.messages, data.has_older),
    [data]
  );
  // A fresh read of the page (after a retry, or a schedule changed elsewhere)
  // starts the header, schedule and thread over from it.
  const [header, setHeader] = useStateFor<BftTaskHeader>(data, data.task);
  const [schedule, setSchedule] = useStateFor<BftTaskSchedule>(data, data.schedule);
  const [thread, setThread] = useStateFor<Thread>(data, initialThread);
  const [pollFailed, setPollFailed] = useState(false);
  const manage = data.project.role === "admin";

  const latest = useRef({ header, schedule, thread, onRefresh });
  latest.current = { header, schedule, thread, onRefresh };
  // Bumped when the thread starts over in place: replies to older requests
  // are dropped.
  const generation = useRef(0);

  // A header from a poll or a write. A schedule added or removed elsewhere
  // reads the page again for its recurrence.
  const applyHeader = useCallback(
    (next: BftTaskHeader) => {
      const scheduledNow = latest.current.schedule.status !== "none";
      setHeader(next);
      if (next.scheduled !== scheduledNow) latest.current.onRefresh();
    },
    [setHeader]
  );

  const emptyPolls = useRef(0);
  const poll = useCallback(
    async (signal: AbortSignal): Promise<"more" | "changed" | "idle"> => {
      const round = generation.current;
      const cursor = latest.current.thread.tailId;
      const check = cursor !== null && emptyPolls.current >= cursorCheckAfter;
      const page = await api.taskMessages(
        org,
        project,
        task,
        cursor && !check ? { after: cursor } : null,
        signal
      );
      if (signal.aborted || round !== generation.current) return "idle";
      // A latest page answers only what follows the cursor; without the
      // cursor in it, the thread starts over.
      const at = check ? page.messages.findIndex((item) => item.id === cursor) : -1;
      const lost = check && at < 0;
      const fresh = check ? page.messages.slice(at + 1) : page.messages;
      setThread((previous) =>
        // Only the reply to the newest cursor applies; anything else is late.
        previous.tailId !== cursor
          ? previous
          : cursor && !lost
            ? appendNewer(previous, fresh)
            : startThread(page.messages, page.has_more)
      );
      emptyPolls.current =
        cursor && !check && fresh.length === 0 ? emptyPolls.current + 1 : 0;
      applyHeader(page.task);
      setPollFailed(false);
      if (cursor && !check && page.has_more) return "more";
      return fresh.length > 0 || lost ? "changed" : "idle";
    },
    [api, org, project, task, setThread, applyHeader]
  );

  const wake = usePolling(poll, header.terminal, () => setPollFailed(true));

  const jumpToLatest = useCallback(() => {
    generation.current += 1;
    const round = generation.current;
    api.taskMessages(org, project, task, null).then(
      (page) => {
        if (round !== generation.current) return;
        setThread(startThread(page.messages, page.has_more));
        applyHeader(page.task);
      },
      () => setPollFailed(true)
    );
  }, [api, org, project, task, setThread, applyHeader]);

  const applySchedule = useCallback(
    (reply: BftTaskScheduleReply) => {
      setHeader(reply.task);
      setSchedule(reply.schedule);
    },
    [setHeader, setSchedule]
  );

  const reviewWrite = useWrite();
  const accept = () => {
    const version = header.review_version;
    if (version === null) return;
    reviewWrite.run(
      () => api.acceptTaskReview(org, project, task, version),
      (reply) => {
        setHeader(reply.task);
        showFlash({ kind: "info", text: t.completed }, tasksHref);
      }
    );
  };
  // A review that changed under the reader: say so, and read the page again.
  useEffect(() => {
    if (!reviewWrite.error) return;
    showFlash({ kind: "error", text: reviewWrite.error }, tasksHref);
    reviewWrite.reset();
    onRefresh();
  }, [reviewWrite, tasksHref, onRefresh]);

  return (
    <div className="bft-page bft-task-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          {crumb}
          <h1 title={taskTitle(header)}>{taskTitle(header)}</h1>
          <div className="bft-page-meta bft-task-meta">
            <State value={header.status} />
            <span>{kindLabel(header.kind)}</span>
            {header.scheduled ? (
              <span className="bft-tag">{t.scheduledTag}</span>
            ) : null}
          </div>
        </div>
        {header.review_version !== null ? (
          <div className="bft-page-actions">
            <button
              className="bft-btn bft-btn-primary"
              disabled={reviewWrite.busy}
              onClick={accept}
              type="button"
            >
              {reviewWrite.busy ? t.completing : t.markComplete}
            </button>
          </div>
        ) : null}
      </div>
      {stale || pollFailed ? (
        <StaleNotice
          onRetry={() => {
            setPollFailed(false);
            if (stale) onRetry();
            else wake();
          }}
        />
      ) : null}
      <div className="bft-task-grid">
        <Conversation
          jumpToLatest={jumpToLatest}
          onSent={wake}
          org={org}
          project={project}
          setThread={setThread}
          task={task}
          thread={thread}
          generation={generation}
        />
        <aside aria-label={t.detailsLabel} className="bft-panel bft-task-rail">
          <ScrollArea
            className="bft-panel-scroll"
            edgeEffect="none"
            orientation="vertical"
            scrollbarVisibility="hover"
            viewportClassName="bft-scroll-viewport"
          >
            <div className="bft-rail-body">
              {header.schedulable ? (
                <ScheduleSection
                  manage={manage}
                  onApplied={applySchedule}
                  onRetry={onRefresh}
                  org={org}
                  project={project}
                  schedule={schedule}
                  task={task}
                  tasksHref={tasksHref}
                />
              ) : null}
              <Participants participants={data.participants} />
            </div>
          </ScrollArea>
        </aside>
      </div>
    </div>
  );
}

/**
 * Runs `poll` one request at a time while the tab is visible, waiting
 * `pollIntervalMs` after a change and backing off to `pollMaxIntervalMs`
 * while nothing changes. A terminal task is polled only within
 * `pollLingerMs` of a `wake()` or a change.
 */
function usePolling(
  poll: (signal: AbortSignal) => Promise<"more" | "changed" | "idle">,
  terminal: boolean,
  onFailure: () => void
) {
  const latest = useRef({ poll, terminal, onFailure });
  latest.current = { poll, terminal, onFailure };
  const wakeRef = useRef<() => void>(() => undefined);

  useEffect(() => {
    let stopped = false;
    let timer: number | undefined;
    let inflight: AbortController | null = null;
    let again = false;
    let delay = pollIntervalMs;
    let lingerUntil = 0;
    const active = () => !latest.current.terminal || Date.now() < lingerUntil;

    const schedule = (ms: number) => {
      window.clearTimeout(timer);
      timer = undefined;
      if (stopped || document.hidden) return;
      timer = window.setTimeout(tick, ms);
    };
    const tick = () => {
      timer = undefined;
      if (stopped || document.hidden) return;
      if (inflight) {
        again = true;
        return;
      }
      const controller = new AbortController();
      inflight = controller;
      latest.current.poll(controller.signal).then(
        (result) => {
          if (controller.signal.aborted) return;
          inflight = null;
          if (result !== "idle") lingerUntil = Date.now() + pollLingerMs;
          delay = nextPollDelay(delay, result !== "idle");
          if (result === "more" || again) {
            again = false;
            schedule(0);
          } else if (active()) schedule(delay);
        },
        () => {
          if (controller.signal.aborted) return;
          inflight = null;
          latest.current.onFailure();
          delay = nextPollDelay(delay, false);
          if (active()) schedule(delay);
        }
      );
    };
    const onVisibility = () => {
      if (document.hidden) {
        window.clearTimeout(timer);
        timer = undefined;
        inflight?.abort();
        inflight = null;
      } else if (active()) {
        delay = pollIntervalMs;
        tick();
      }
    };
    wakeRef.current = () => {
      lingerUntil = Date.now() + pollLingerMs;
      delay = pollIntervalMs;
      window.clearTimeout(timer);
      tick();
    };
    document.addEventListener("visibilitychange", onVisibility);
    if (active()) schedule(delay);
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      inflight?.abort();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);

  // A task that becomes active again (a send reopens it) resumes polling.
  const wasTerminal = useRef(terminal);
  useEffect(() => {
    if (wasTerminal.current && !terminal) wakeRef.current();
    wasTerminal.current = terminal;
  }, [terminal]);

  return useCallback(() => wakeRef.current(), []);
}

function Conversation({
  org,
  project,
  task,
  thread,
  setThread,
  generation,
  jumpToLatest,
  onSent,
}: {
  org: string;
  project: string;
  task: string;
  thread: Thread;
  setThread: (update: (previous: Thread) => Thread) => void;
  generation: RefObject<number>;
  jumpToLatest: () => void;
  onSent: () => void;
}) {
  const api = useApi();
  const titleId = useId();
  const viewport = useRef<HTMLDivElement>(null);
  const [older, setOlder] = useState({ loading: false, failed: false });
  const atBottom = useRef(true);
  // Kept across a prepend so the messages in view stay where they were.
  const anchor = useRef<{ height: number; top: number } | null>(null);
  const loading = useRef<AbortController | null>(null);
  useEffect(() => () => loading.current?.abort(), []);
  const shown = useRef(thread);
  shown.current = thread;

  const first = thread.messages[0]?.id;
  const last = thread.messages.at(-1)?.id;

  useLayoutEffect(() => {
    const element = viewport.current;
    if (!element) return;
    if (anchor.current) {
      element.scrollTop =
        anchor.current.top + (element.scrollHeight - anchor.current.height);
      anchor.current = null;
    } else if (atBottom.current) {
      element.scrollTop = element.scrollHeight;
    }
  }, [first, last]);

  const loadOlder = () => {
    if (!first || older.loading) return;
    const round = generation.current;
    const controller = new AbortController();
    loading.current = controller;
    setOlder({ loading: true, failed: false });
    api.taskMessages(org, project, task, { before: first }, controller.signal).then(
      (page) => {
        if (controller.signal.aborted || round !== generation.current) return;
        const element = viewport.current;
        // Only a page that puts older messages first moves the content; the
        // layout effect then consumes the anchor.
        const current = shown.current;
        const grows =
          current.messages[0]?.id === first &&
          prependOlder(current, page.messages, page.has_more).messages[0]?.id !== first;
        anchor.current =
          grows && element
            ? { height: element.scrollHeight, top: element.scrollTop }
            : null;
        setThread((previous) =>
          previous.messages[0]?.id === first
            ? prependOlder(previous, page.messages, page.has_more)
            : previous
        );
        setOlder({ loading: false, failed: false });
      },
      () => {
        if (!controller.signal.aborted) setOlder({ loading: false, failed: true });
      }
    );
  };

  return (
    <section aria-labelledby={titleId} className="bft-panel bft-task-thread">
      <div className="bft-panel-header">
        <h2 id={titleId}>{t.threadTitle}</h2>
      </div>
      <ScrollArea
        className="bft-panel-scroll"
        edgeEffect="none"
        // Content that grows under a reader at the end (late layout, a new
        // message) keeps the end in view.
        onContentResize={() => {
          const element = viewport.current;
          if (element && atBottom.current && !anchor.current)
            element.scrollTop = element.scrollHeight;
        }}
        onScroll={(event) => {
          const element = event.currentTarget;
          atBottom.current =
            element.scrollHeight - element.scrollTop - element.clientHeight < 48;
        }}
        orientation="vertical"
        ref={viewport}
        scrollbarVisibility="hover"
        viewportClassName="bft-scroll-viewport bft-task-scroll"
      >
        {thread.messages.length === 0 ? (
          <p className="bft-quiet">{t.threadEmpty}</p>
        ) : (
          <>
            <ScrollAreaLoadMore
              edge="start"
              failed={older.failed}
              hasMore={thread.hasOlder}
              loading={older.loading}
              onLoadMore={loadOlder}
              quiet
            />
            {older.loading ? (
              <output className="bft-quiet">{t.loadingOlder}</output>
            ) : null}
            {older.failed ? (
              <div className="bft-quiet-row" role="alert">
                <p className="bft-quiet bft-quiet-inline">{t.loadOlderFailed}</p>
                <button
                  className="bft-btn bft-btn-sm"
                  onClick={loadOlder}
                  type="button"
                >
                  {messages.states.retry}
                </button>
              </div>
            ) : null}
            <ol className="bft-thread">
              {thread.messages.map((message) => (
                <Message key={message.id} message={message} />
              ))}
            </ol>
            {thread.detached ? (
              <div className="bft-quiet-row">
                <p className="bft-quiet bft-quiet-inline">
                  {thread.unseen > 0 ? t.newerHidden(thread.unseen) : t.olderTrimmed}
                </p>
                <button
                  className="bft-btn bft-btn-sm"
                  onClick={() => {
                    atBottom.current = true;
                    jumpToLatest();
                  }}
                  type="button"
                >
                  {t.showLatest}
                </button>
              </div>
            ) : null}
          </>
        )}
      </ScrollArea>
      <Composer
        onSent={() => {
          atBottom.current = true;
          if (thread.detached) jumpToLatest();
          onSent();
        }}
        org={org}
        project={project}
        task={task}
      />
    </section>
  );
}

function Message({ message }: { message: BftTaskMessage }) {
  const time = message.created_at ? Date.parse(message.created_at) : Number.NaN;
  return (
    <li className="bft-message" data-person={message.from_person ? "" : undefined}>
      <div className="bft-message-head">
        <span className="bft-message-author">{message.author}</span>
        {Number.isNaN(time) ? null : (
          <time dateTime={message.created_at ?? undefined} title={formatDateTime(time)}>
            {formatRelative(message.created_at ?? "")}
          </time>
        )}
      </div>
      {message.blocks.map((block, index) =>
        block.type === "text" ? (
          <div
            className="bft-markdown"
            // Sanitized by the server (MDEx): no scripts or raw HTML.
            dangerouslySetInnerHTML={{ __html: block.html }}
            key={index}
          />
        ) : (
          <div className="bft-attachment" key={index}>
            <div className="bft-attachment-name">{block.name}</div>
            <div className="bft-attachment-meta">
              <span>
                {block.kind === "image" ? t.attachmentImage : t.attachmentFile}
              </span>
              {block.mime ? <span>{block.mime}</span> : null}
            </div>
            {block.path ? (
              <div className="bft-attachment-path">{block.path}</div>
            ) : null}
            {block.href ? (
              <a
                aria-label={t.downloadLabel(block.name)}
                className="bft-link"
                href={block.href}
              >
                {t.download}
              </a>
            ) : null}
          </div>
        )
      )}
    </li>
  );
}

/** The steering composer. The draft survives a reload until it is sent. */
function Composer({
  org,
  project,
  task,
  onSent,
}: {
  org: string;
  project: string;
  task: string;
  onSent: () => void;
}) {
  const api = useApi();
  const key = draftKey(org, project, task);
  const [text, setText] = useState(() => readDraft(key));
  const typed = useRef(text);
  typed.current = text;
  const [state, setState] = useState<{
    busy: boolean;
    error: string | undefined;
    sent: boolean;
  }>({ busy: false, error: undefined, sent: false });
  // One id per draft: a retry of the same text appends one message.
  const requestId = useRef<string | null>(null);
  const hintId = useId();

  const change = (value: string) => {
    typed.current = value;
    setText(value);
    writeDraft(key, value);
    requestId.current = null;
    if (state.sent || state.error)
      setState({ busy: false, error: undefined, sent: false });
  };

  const send = () => {
    if (state.busy || text.trim() === "") return;
    requestId.current ??= newRequestId();
    const sent = text;
    setState({ busy: true, error: undefined, sent: false });
    api
      .sendTaskMessage(org, project, task, {
        text: sent,
        request_id: requestId.current,
      })
      .then(
        () => {
          // Only the text that was sent leaves the composer: anything typed
          // while it was sending stays, with its draft.
          const now = typed.current;
          const rest = now.startsWith(sent) ? now.slice(sent.length).trimStart() : now;
          typed.current = rest;
          setText(rest);
          writeDraft(key, rest);
          requestId.current = null;
          setState({ busy: false, error: undefined, sent: true });
          onSent();
        },
        (error: unknown) =>
          setState({ busy: false, error: writeErrorMessage(error), sent: false })
      );
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      send();
    }
  };

  return (
    <form
      className="bft-composer"
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <textarea
        aria-describedby={hintId}
        aria-label={t.composerLabel}
        className="bft-textarea bft-composer-input"
        onChange={(event) => change(event.target.value)}
        onKeyDown={onKeyDown}
        placeholder={t.composerPlaceholder}
        rows={3}
        value={text}
      />
      <div className="bft-composer-actions">
        {state.error ? (
          <p className="bft-dialog-error" role="alert">
            {state.error}
          </p>
        ) : state.sent ? (
          <output className="bft-form-saved">{t.sent}</output>
        ) : (
          <small className="bft-quiet-inline bft-composer-hint" id={hintId}>
            {t.composerHint}
          </small>
        )}
        <button
          className="bft-btn"
          disabled={state.busy || text.trim() === ""}
          type="submit"
        >
          {state.busy ? t.sending : t.send}
        </button>
      </div>
    </form>
  );
}

function ScheduleSection({
  org,
  project,
  task,
  schedule,
  manage,
  tasksHref,
  onApplied,
  onRetry,
}: {
  org: string;
  project: string;
  task: string;
  schedule: BftTaskSchedule;
  manage: boolean;
  tasksHref: string;
  onApplied: (reply: BftTaskScheduleReply) => void;
  onRetry: () => void;
}) {
  const api = useApi();
  const [editing, setEditing] = useState(false);
  const confirm = useConfirm();
  const scheduled = schedule.status === "ok";
  const titleId = useId();

  return (
    <section aria-labelledby={titleId} className="bft-rail-section bft-task-section">
      <div className="bft-task-section-head">
        <h3 id={titleId}>{t.scheduleTitle}</h3>
        {manage && (schedule.status === "ok" || schedule.status === "none") ? (
          <button
            className="bft-btn bft-btn-sm"
            onClick={() => setEditing(true)}
            type="button"
          >
            {scheduled ? t.editSchedule : t.addSchedule}
          </button>
        ) : null}
      </div>
      {schedule.status === "none" ? (
        <p className="bft-quiet-inline bft-task-note">{t.scheduleNone}</p>
      ) : schedule.status === "missing" ? (
        <p className="bft-quiet-inline bft-task-note" role="alert">
          {t.scheduleMissing}
        </p>
      ) : schedule.status === "unavailable" ? (
        <div className="bft-quiet-row bft-quiet-row-flush">
          <p className="bft-quiet bft-quiet-inline">{t.scheduleUnavailable}</p>
          <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : (
        <>
          <p className="bft-task-recurrence">{schedule.recurrence}</p>
          {schedule.command ? (
            <>
              <span className="bft-task-label">{t.scheduleCommand}</span>
              <p className="bft-prompt">{schedule.command}</p>
            </>
          ) : null}
          {manage ? (
            <button
              className="bft-link bft-link-button bft-link-danger"
              onClick={() =>
                confirm.ask({
                  title: t.deleteSchedule,
                  description: t.deleteScheduleBody,
                  confirmLabel: t.delete,
                  action: () =>
                    api.deleteTaskSchedule(org, project, task).then((reply) => {
                      onApplied(reply);
                      showFlash({ kind: "info", text: t.scheduleDeleted }, tasksHref);
                    }),
                })
              }
              type="button"
            >
              {t.deleteSchedule}
            </button>
          ) : null}
        </>
      )}
      {editing ? (
        <ScheduleDialog
          adding={!scheduled}
          initial={schedule.form}
          onClose={() => setEditing(false)}
          onSaved={(reply) => {
            onApplied(reply);
            setEditing(false);
            showFlash({ kind: "info", text: t.scheduleSaved }, tasksHref);
          }}
          org={org}
          project={project}
          task={task}
        />
      ) : null}
      {confirm.dialog}
    </section>
  );
}

/** Whether the form names a recurrence worth previewing. */
export function hasRecurrence(
  form: Pick<BftTaskScheduleForm, "mode" | "cron" | "interval_value">
) {
  return form.mode === "cron"
    ? form.cron.trim() !== ""
    : form.interval_value.trim() !== "";
}

function ScheduleDialog({
  org,
  project,
  task,
  adding,
  initial,
  onSaved,
  onClose,
}: {
  org: string;
  project: string;
  task: string;
  adding: boolean;
  initial: BftTaskScheduleForm;
  onSaved: (reply: BftTaskScheduleReply) => void;
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [form, setForm] = useState(initial);
  const [preview, setPreview] = useState<string | null>(null);
  const set = <K extends keyof BftTaskScheduleForm>(
    key: K,
    value: BftTaskScheduleForm[K]
  ) => setForm((previous) => ({ ...previous, [key]: value }));

  // The server says how the recurrence reads, as the saved schedule will.
  const recurrenceKey = JSON.stringify({
    mode: form.mode,
    interval_value: form.interval_value,
    interval_unit: form.interval_unit,
    cron: form.cron,
    timezone: form.timezone,
  });
  useEffect(() => {
    const current = JSON.parse(recurrenceKey) as Omit<BftTaskScheduleForm, "command">;
    if (!hasRecurrence(current)) {
      setPreview(null);
      return undefined;
    }
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      api.previewTaskSchedule(org, project, task, current, controller.signal).then(
        (reply) => {
          if (!controller.signal.aborted) setPreview(reply.recurrence);
        },
        () => undefined
      );
    }, 250);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [api, org, project, task, recurrenceKey]);

  return (
    <FormDialog
      description={t.scheduleDialogBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() =>
        write.run(() => api.saveTaskSchedule(org, project, task, form), onSaved)
      }
      submitLabel={t.saveSchedule}
      title={adding ? t.scheduleDialogAdd : t.scheduleDialogEdit}
      write={write}
    >
      <fieldset className="bft-task-modes">
        <legend>{t.scheduleType}</legend>
        {(["cron", "interval"] as const).map((mode) => (
          <label className="bft-task-mode" key={mode}>
            <input
              checked={form.mode === mode}
              disabled={write.busy}
              name="schedule-mode"
              onChange={() => set("mode", mode)}
              type="radio"
              value={mode}
            />
            {mode === "cron" ? t.modeCron : t.modeInterval}
          </label>
        ))}
      </fieldset>
      {form.mode === "cron" ? (
        <>
          <TextField
            disabled={write.busy}
            hint={t.cronHint}
            label={t.cron}
            onChange={(value) => set("cron", value)}
            placeholder="0 17 * * *"
            value={form.cron}
          />
          <TextField
            disabled={write.busy}
            label={t.timezone}
            onChange={(value) => set("timezone", value)}
            placeholder="UTC"
            value={form.timezone}
          />
        </>
      ) : (
        <div className="bft-task-interval">
          <TextField
            disabled={write.busy}
            label={t.repeatEvery}
            onChange={(value) => set("interval_value", value.replace(/[^0-9]/g, ""))}
            value={form.interval_value}
          />
          <Dropdown
            className="bft-form-field"
            disabled={write.busy}
            items={taskScheduleIntervalUnits.map((unit) => ({
              id: unit,
              label: t.units[unit],
            }))}
            label={t.unit}
            onChange={(value) =>
              set(
                "interval_unit",
                taskScheduleIntervalUnits.find((unit) => unit === value) ?? "days"
              )
            }
            size="sm"
            value={form.interval_unit}
          />
        </div>
      )}
      {preview ? <output className="bft-task-preview">{preview}</output> : null}
      <TextAreaField
        disabled={write.busy}
        label={t.command}
        onChange={(value) => set("command", value)}
        rows={4}
        value={form.command}
      />
    </FormDialog>
  );
}

function Participants({
  participants,
}: {
  participants: BftSwarmTaskDetail["participants"];
}) {
  const titleId = useId();
  return (
    <section aria-labelledby={titleId} className="bft-rail-section bft-task-section">
      <div className="bft-task-section-head">
        <h3 id={titleId}>{t.participantsTitle}</h3>
        <span className="bft-count">{participants.length}</span>
      </div>
      {participants.length === 0 ? (
        <p className="bft-quiet-inline bft-task-note">{t.participantsEmpty}</p>
      ) : (
        <ul className="bft-task-participants">
          {participants.map((participant) => (
            <li key={participant.id || participant.label}>
              {participant.agent_href ? (
                <a
                  className="bft-link bft-truncate"
                  href={participant.agent_href}
                  onClick={spaLinkClick}
                  title={participant.label}
                >
                  {participant.label}
                </a>
              ) : (
                <span className="bft-truncate" title={participant.label}>
                  {participant.label}
                </span>
              )}
              {participant.role_label ? (
                <span className="bft-task-role">
                  {humanize(participant.role_label)}
                </span>
              ) : null}
              {participant.thread_url ? (
                <a
                  aria-label={t.openThreadLabel(participant.label)}
                  className="bft-link bft-task-thread-link"
                  href={participant.thread_url}
                  rel="noopener noreferrer"
                  target="_blank"
                >
                  {t.openThread}
                </a>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
