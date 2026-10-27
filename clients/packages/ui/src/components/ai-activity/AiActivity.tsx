import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type HTMLAttributes,
  type ReactNode,
  type TransitionEvent,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import { scheduleLayoutRead, uiClock, type CancelUiTimer } from "../../clock";
import { Collapse, CollapseContent } from "../collapse";
import { ChevronDownSmallIcon, CircleXIcon } from "../icons";
import { ScrollArea } from "../scroll-area";
import { isReducedMotionEnabled, motionDuration } from "../../tokens";
import { Tooltip } from "../tooltip";
import { cx } from "../utils";
import { useGradientShimmer } from "./useGradientShimmer";

/** Normalized presentation phases for Salix aggregate activity updates. */
export type AiActivityPhase = "thinking" | "execution" | "messaging";

/** `idle` clears the activity surface, so it is intentionally not rendered. */
export type AiActivityStatus = "running" | "complete" | "failed";
export type AiActivityEventStatus = "running" | "complete" | "failed";

const activityHistoryEdgeBlur = {
  blurCurve: 1.6,
  endSize: 24,
  layers: 2,
  maskCoverage: 56,
  maskCurve: 1.6,
  maxBlur: 3,
  minBlur: 0,
  startSize: 24,
} as const;

export interface AiActivityEvent {
  id: string;
  /** A bounded, user-safe summary. Never pass raw chain-of-thought or tool arguments. */
  summary: ReactNode;
  phase: AiActivityPhase;
  status?: AiActivityEventStatus;
  /** Stable public tool name, when this event represents execution. */
  toolName?: string;
}

export interface AiActivityProps extends Omit<HTMLAttributes<HTMLElement>, "children"> {
  /** Stable identity for the visible headline. Required when a non-string summary can change. */
  activityKey?: string | number;
  /** Public display name for the agent responsible for the current activity. */
  actor?: string;
  /** Completed or explicitly public events; the active headline is kept separate. */
  events?: readonly AiActivityEvent[];
  /** A richer trace rendered inside the disclosure instead of event rows. */
  details?: ReactNode;
  /** A failure's further words and ways out, under its copy inside the notice card. */
  notice?: ReactNode;
  phase?: AiActivityPhase;
  /** The committed, user-visible answer or artifact. */
  result?: ReactNode;
  /** Presentation status. `complete` settles this UI segment, not its Conversation. */
  status: AiActivityStatus;
  summary: ReactNode;
  /** Active-process treatment. Product adapters should pass semantic running authority. */
  shimmer?: boolean;
  /** Stable public tool name from the current execution activity. */
  toolName?: string;
  defaultExpanded?: boolean;
  /** Automatically collapse an expanded disclosure when the activity completes. */
  collapseOnComplete?: boolean;
  expanded?: boolean;
  onExpandedChange?: (expanded: boolean) => void;
}

export interface AiWorkerActivityMessage {
  id: string;
  sender: string;
  /** A bounded message that crossed the Router/Worker boundary. */
  content: ReactNode;
}

export interface AiWorkerActivityProps extends Omit<
  HTMLAttributes<HTMLDivElement>,
  "children"
> {
  /** Public display name for the delegated agent. */
  actor?: string;
  status: AiActivityStatus;
  /** Read-only messages exchanged across the Router/Worker boundary. */
  messages?: readonly AiWorkerActivityMessage[];
}

interface ActivitySnapshot {
  key: string;
  shimmer: boolean;
  summary: ReactNode;
  toolName?: string;
}

const activityTextSwapFallbackMs = motionDuration.stateChange + 100;

function resolveActivityKey({
  activityKey,
  phase,
  status,
  summary,
  toolName,
  actor,
}: {
  activityKey: string | number | undefined;
  actor: string | undefined;
  phase: AiActivityPhase | undefined;
  status: AiActivityStatus;
  summary: ReactNode;
  toolName: string | undefined;
}) {
  if (activityKey != null) return `${status}:${activityKey}`;
  const contentKey = typeof summary === "string" ? summary : "activity";
  return `${status}:${actor ?? "agent"}:${phase ?? "activity"}:${contentKey}:${toolName ?? ""}`;
}

function ActivityTextLayer({
  ariaHidden,
  motion,
  onTransitionEnd,
  snapshot,
}: {
  ariaHidden?: boolean;
  motion: "enter" | "exit" | "rest";
  onTransitionEnd?: (event: TransitionEvent<HTMLSpanElement>) => void;
  snapshot: ActivitySnapshot;
}) {
  const summaryRef = useRef<HTMLSpanElement>(null);
  const shimmerActive = snapshot.shimmer && (!ariaHidden || motion === "rest");
  useGradientShimmer(summaryRef, {
    active: shimmerActive,
    // The activity, not its text: a summary that ticks in place (the seconds
    // a wait has lasted) must not restart the sweep; the next sweep re-measures.
    contentIdentity: snapshot.key,
  });

  return (
    <span
      aria-hidden={ariaHidden}
      className="comma-ai-activity-text-layer"
      data-motion={motion}
      data-motion-key={snapshot.key}
      onTransitionEnd={onTransitionEnd}
    >
      <span
        className="comma-ai-activity-text-summary"
        data-shimmer={shimmerActive ? "true" : "false"}
        ref={summaryRef}
      >
        {snapshot.summary}
      </span>
      {snapshot.toolName ? (
        <code className="comma-ai-activity-tool-name">{snapshot.toolName}</code>
      ) : null}
    </span>
  );
}

function ActivityText({
  motionKey,
  shimmer,
  summary,
  toolName,
}: {
  motionKey: string;
  shimmer: boolean;
  summary: ReactNode;
  toolName?: string;
}) {
  const snapshot: ActivitySnapshot = {
    key: motionKey,
    shimmer,
    summary,
    ...(toolName ? { toolName } : {}),
  };
  const textRef = useRef<HTMLSpanElement>(null);
  const currentRef = useRef(snapshot);
  const pendingRef = useRef<ActivitySnapshot | null>(null);
  const previousWidthRef = useRef<number | null>(null);
  // The text's width as last laid out. A swap starts in the commit that
  // changed the transcript around it; measuring then would lay the whole
  // page out inside the commit, so the width is kept from the layouts that
  // already happened.
  const textWidthRef = useRef<number | null>(null);
  const swapActiveRef = useRef(false);
  const [current, setCurrent] = useState(snapshot);
  const [outgoing, setOutgoing] = useState<ActivitySnapshot | null>(null);
  const [playing, setPlaying] = useState(false);

  useLayoutEffect(() => {
    const text = textRef.current;
    if (!text || typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        textWidthRef.current =
          entry.borderBoxSize?.[0]?.inlineSize ?? entry.contentRect.width;
      }
    });
    observer.observe(text);
    return () => observer.disconnect();
  }, []);

  useLayoutEffect(() => {
    const previous = currentRef.current;
    const next = {
      key: motionKey,
      shimmer,
      summary,
      ...(toolName ? { toolName } : {}),
    };

    if (isReducedMotionEnabled()) {
      textRef.current
        ?.closest<HTMLElement>(".comma-ai-activity-summary-shell")
        ?.style.removeProperty("--ai-activity-chevron-shift");
      currentRef.current = next;
      pendingRef.current = null;
      swapActiveRef.current = false;
      setCurrent(next);
      setOutgoing(null);
      setPlaying(false);
      return;
    }

    if (swapActiveRef.current) {
      if (previous.key === motionKey) {
        currentRef.current = next;
        pendingRef.current = null;
        setCurrent(next);
      } else {
        pendingRef.current = next;
      }
      return;
    }

    if (previous.key === motionKey) {
      currentRef.current = next;
      setCurrent(next);
      return;
    }

    previousWidthRef.current = textWidthRef.current;
    currentRef.current = next;
    pendingRef.current = null;
    swapActiveRef.current = true;
    setOutgoing(previous);
    setCurrent(next);
    setPlaying(false);
  }, [motionKey, shimmer, summary, toolName]);

  // The chevron starts the swap where the previous text left it: its shift is
  // read and written in the frame's shared layout phase, before the swapped
  // text first paints, and released two frames later (below).
  useLayoutEffect(() => {
    if (outgoing == null || previousWidthRef.current == null) return undefined;
    const previousWidth = previousWidthRef.current;
    return scheduleLayoutRead(() => {
      const text = textRef.current;
      const summaryElement = text?.closest<HTMLElement>(
        ".comma-ai-activity-summary-shell"
      );
      if (!text || !summaryElement) return undefined;
      const shift = previousWidth - text.getBoundingClientRect().width;
      if (Math.abs(shift) < 0.5) return undefined;
      return () => {
        summaryElement.style.setProperty("--ai-activity-chevron-shift", `${shift}px`);
      };
    });
  }, [current.key, outgoing]);

  const settleCurrentSwap = useCallback((expectedCurrentKey: string) => {
    if (currentRef.current.key !== expectedCurrentKey) return;

    const settled = currentRef.current;
    const pending = pendingRef.current;
    pendingRef.current = null;

    if (pending != null && pending.key !== settled.key && !isReducedMotionEnabled()) {
      previousWidthRef.current = textWidthRef.current;
      currentRef.current = pending;
      setOutgoing(settled);
      setCurrent(pending);
      setPlaying(false);
      return;
    }

    if (pending != null) {
      currentRef.current = pending;
      setCurrent(pending);
    }
    swapActiveRef.current = false;
    setOutgoing(null);
    setPlaying(false);
  }, []);

  useEffect(() => {
    if (outgoing == null) return;
    const expectedCurrentKey = current.key;
    let playFrame: CancelUiTimer | undefined;
    let settleTimer: CancelUiTimer | undefined;
    const paintFrame = uiClock.frame(() => {
      playFrame = uiClock.frame(() => {
        if (currentRef.current.key !== expectedCurrentKey) return;
        textRef.current
          ?.closest<HTMLElement>(".comma-ai-activity-summary-shell")
          ?.style.setProperty("--ai-activity-chevron-shift", "0px");
        setPlaying(true);
        settleTimer = uiClock.after(activityTextSwapFallbackMs, () => {
          settleCurrentSwap(expectedCurrentKey);
        });
      });
    });
    return () => {
      paintFrame();
      if (playFrame != null) playFrame();
      if (settleTimer != null) settleTimer();
    };
  }, [current.key, outgoing, settleCurrentSwap]);

  const finishSwap = (event: TransitionEvent<HTMLSpanElement>) => {
    if (
      event.currentTarget !== event.target ||
      event.propertyName !== "transform" ||
      !playing ||
      event.currentTarget.dataset.motionKey !== currentRef.current.key
    ) {
      return;
    }
    settleCurrentSwap(currentRef.current.key);
  };

  return (
    <span
      className="comma-ai-activity-text"
      data-playing={playing ? "true" : "false"}
      data-swapping={outgoing ? "true" : "false"}
      ref={textRef}
    >
      {outgoing ? (
        <ActivityTextLayer
          ariaHidden
          key={outgoing.key}
          motion={playing ? "exit" : "rest"}
          snapshot={outgoing}
        />
      ) : null}
      <ActivityTextLayer
        key={current.key}
        motion={outgoing && !playing ? "enter" : "rest"}
        onTransitionEnd={finishSwap}
        snapshot={current}
      />
    </span>
  );
}

function ActivityEventRow({
  animateEntry,
  event,
}: {
  animateEntry: boolean;
  event: AiActivityEvent;
}) {
  const contentRef = useRef<HTMLDivElement>(null);
  const [entered, setEntered] = useState(!animateEntry);
  const [settled, setSettled] = useState(!animateEntry);
  const [targetHeight, setTargetHeight] = useState<number | null>(null);

  useLayoutEffect(() => {
    if (!animateEntry) return;
    const content = contentRef.current;
    if (content == null) return;

    if (isReducedMotionEnabled()) {
      setEntered(true);
      setSettled(true);
      return;
    }

    setTargetHeight(content.getBoundingClientRect().height);
    let playFrame: CancelUiTimer | undefined;
    const paintFrame = uiClock.frame(() => {
      playFrame = uiClock.frame(() => setEntered(true));
    });

    return () => {
      paintFrame();
      if (playFrame != null) playFrame();
    };
  }, [animateEntry]);

  const finishEntry = (transition: TransitionEvent<HTMLLIElement>) => {
    if (transition.propertyName !== "height" || !entered) return;
    setSettled(true);
  };

  const style =
    targetHeight == null
      ? undefined
      : ({ "--ai-activity-event-height": `${targetHeight}px` } as CSSProperties);

  return (
    <li
      className="comma-ai-activity-event"
      data-entered={entered ? "true" : "false"}
      data-phase={event.phase}
      data-settled={settled ? "true" : "false"}
      data-status={event.status ?? "complete"}
      onTransitionEnd={finishEntry}
      style={style}
    >
      <div className="comma-ai-activity-event-content" ref={contentRef}>
        <span>{event.summary}</span>
        {event.toolName ? (
          <code className="comma-ai-activity-tool-name">{event.toolName}</code>
        ) : null}
      </div>
    </li>
  );
}

function ActivityEventList({
  events,
  initialEventIds,
}: {
  events: readonly AiActivityEvent[];
  initialEventIds: ReadonlySet<string> | null;
}) {
  return (
    <ScrollArea
      className="comma-ai-activity-events-scroll"
      data-capped={events.length > 8 ? "true" : undefined}
      edgeBlur={activityHistoryEdgeBlur}
      edgeEffect="blur"
      orientation="vertical"
      scrollbar={false}
      viewportProps={{ "aria-label": "Activity history" }}
    >
      <ol className="comma-ai-activity-events">
        {events.map((event) => (
          <ActivityEventRow
            animateEntry={!initialEventIds?.has(event.id)}
            event={event}
            key={event.id}
          />
        ))}
      </ol>
    </ScrollArea>
  );
}

export function AiActivity({
  activityKey,
  actor,
  className,
  collapseOnComplete = false,
  defaultExpanded = false,
  details,
  events = [],
  expanded: controlledExpanded,
  notice,
  onExpandedChange,
  phase,
  result,
  shimmer,
  status,
  summary,
  toolName,
  ...props
}: AiActivityProps) {
  const historyId = useId();
  const summaryId = `${historyId}-summary`;
  const disclosureRef = useRef<HTMLButtonElement>(null);
  const panelHeightFrame = useRef<CancelUiTimer | null>(null);
  const panelShellRef = useRef<HTMLDivElement>(null);
  const panelWasInitialized = useRef(false);
  const initialEventIds = useRef<ReadonlySet<string> | null>(null);
  if (initialEventIds.current == null) {
    initialEventIds.current = new Set(events.map((event) => event.id));
  }
  const [uncontrolledExpanded, setUncontrolledExpanded] = useState(defaultExpanded);
  const expanded = controlledExpanded ?? uncontrolledExpanded;
  const previousStatus = useRef(status);
  const previousExpanded = useRef(expanded);
  const hasHistory = details != null || events.length > 0;
  const disclosureOpen = hasHistory && expanded;
  const visibleToolName = phase === "execution" ? toolName : undefined;
  const motionKey = resolveActivityKey({
    activityKey,
    actor,
    phase,
    status,
    summary,
    toolName: visibleToolName,
  });
  const activityText = (
    <ActivityText
      motionKey={motionKey}
      shimmer={status === "running" && (shimmer ?? true)}
      summary={summary}
      {...(visibleToolName ? { toolName: visibleToolName } : {})}
    />
  );

  const copy = (
    <span
      aria-live="polite"
      className={cx(status === "failed" && "comma-chat-notice-card-copy")}
      id={summaryId}
      role={status === "failed" ? "alert" : "status"}
    >
      {activityText}
    </span>
  );

  useLayoutEffect(() => {
    const activityCompleted =
      previousStatus.current !== "complete" && status === "complete";
    previousStatus.current = status;
    if (!collapseOnComplete || !activityCompleted || !expanded) return;

    const panelShell = panelShellRef.current;
    if (panelShell?.contains(panelShell.ownerDocument.activeElement)) {
      disclosureRef.current?.focus({ preventScroll: true });
    }
    if (controlledExpanded == null) setUncontrolledExpanded(false);
    onExpandedChange?.(false);
  }, [collapseOnComplete, controlledExpanded, expanded, onExpandedChange, status]);

  useLayoutEffect(() => {
    if (!hasHistory) {
      panelWasInitialized.current = false;
      previousExpanded.current = expanded;
      return;
    }
    const panelShell = panelShellRef.current;
    if (panelShell == null) return;
    if (!panelWasInitialized.current) {
      panelShell.style.height = expanded ? "auto" : "0px";
      panelWasInitialized.current = true;
      previousExpanded.current = expanded;
      return;
    }
    if (previousExpanded.current === expanded) return;
    previousExpanded.current = expanded;

    if (panelHeightFrame.current != null) {
      panelHeightFrame.current();
      panelHeightFrame.current = null;
    }

    if (isReducedMotionEnabled()) {
      panelShell.style.height = expanded ? "auto" : "0px";
      return;
    }

    const currentHeight = panelShell.getBoundingClientRect().height;
    panelShell.style.height = `${currentHeight}px`;
    panelHeightFrame.current = uiClock.frame(() => {
      panelHeightFrame.current = null;
      panelShell.style.height = expanded ? `${panelShell.scrollHeight}px` : "0px";
    });
  }, [expanded, hasHistory]);

  useEffect(
    () => () => {
      if (panelHeightFrame.current != null) {
        panelHeightFrame.current();
      }
    },
    []
  );

  const toggleExpanded = () => {
    const nextExpanded = !expanded;
    if (controlledExpanded == null) setUncontrolledExpanded(nextExpanded);
    onExpandedChange?.(nextExpanded);
  };

  const finishPanelTransition = (transition: TransitionEvent<HTMLDivElement>) => {
    if (
      transition.currentTarget !== transition.target ||
      transition.propertyName !== "height" ||
      !expanded
    ) {
      return;
    }
    transition.currentTarget.style.height = "auto";
  };

  return (
    <section
      {...props}
      aria-busy={status === "running"}
      className={cx("comma-ai-activity", className)}
      data-phase={phase}
      data-slot="ai-activity"
      data-status={status}
    >
      {actor ? <div className="comma-ai-activity-actor">{actor}</div> : null}
      <div className="comma-ai-activity-body">
        <Collapse className="comma-ai-activity-disclosure" open={disclosureOpen}>
          <div
            className={cx(
              "comma-ai-activity-summary-shell",
              !hasHistory && "comma-ai-activity-summary-static",
              // A failure is a chat notice, not a status line: it wears the same
              // card as the thread's send-failure row.
              status === "failed" && "comma-chat-notice-card"
            )}
          >
            {status === "failed" ? (
              <CircleXIcon aria-hidden className="comma-chat-notice-card-icon" />
            ) : null}
            {status === "failed" && notice != null ? (
              <div className="comma-chat-notice-card-content">
                {copy}
                {notice}
              </div>
            ) : (
              copy
            )}
            {hasHistory ? (
              <AriaButton
                aria-controls={historyId}
                aria-expanded={expanded}
                aria-labelledby={summaryId}
                className="comma-ai-activity-summary"
                data-no-press-feedback
                onPress={toggleExpanded}
                ref={disclosureRef}
                type="button"
              >
                <ChevronDownSmallIcon
                  aria-hidden
                  className="comma-ai-activity-chevron"
                />
              </AriaButton>
            ) : null}
          </div>
          {hasHistory ? (
            <div
              className="comma-ai-activity-panel-shell"
              data-expanded={expanded ? "true" : "false"}
              inert={!expanded ? true : undefined}
              onTransitionEnd={finishPanelTransition}
              ref={panelShellRef}
            >
              <CollapseContent
                aria-hidden={!expanded}
                containerClassName="comma-ai-activity-panel"
                forceMount
                id={historyId}
              >
                {details != null ? (
                  <div className="comma-ai-activity-details">{details}</div>
                ) : (
                  <ActivityEventList
                    events={events}
                    initialEventIds={initialEventIds.current}
                  />
                )}
              </CollapseContent>
            </div>
          ) : null}
        </Collapse>

        {status === "complete" && result != null ? (
          <div className="comma-ai-activity-result" data-slot="ai-activity-result">
            {result}
          </div>
        ) : null}
      </div>
    </section>
  );
}

const workerStatusLabels: Record<AiActivityStatus, string> = {
  complete: "done",
  failed: "failed",
  running: "working",
};

/**
 * A compact boundary for delegated work. The Router remains the narrative
 * owner; Worker implementation detail is progressively disclosed on hover or
 * keyboard focus instead of expanding the main activity timeline.
 */
export function AiWorkerActivity({
  actor = "Worker",
  className,
  messages = [],
  status,
  ...props
}: AiWorkerActivityProps) {
  const statusLabel = workerStatusLabels[status];
  const accessibleLabel = `${actor}, ${statusLabel}`;
  const workerCopy = (
    <span
      aria-hidden
      className={cx(
        "comma-ai-worker-activity-copy",
        status === "running" && "comma-shine"
      )}
    >
      <span className="comma-ai-worker-activity-name">{actor}</span>
      <span className="comma-ai-worker-activity-state">{statusLabel}</span>
    </span>
  );

  return (
    <div
      {...props}
      className={cx("comma-ai-worker-activity", className)}
      data-slot="ai-worker-activity"
      data-status={status}
    >
      {messages.length > 0 ? (
        <Tooltip
          arrow="left"
          content={
            <span className="comma-ai-worker-activity-chat">
              <span className="comma-ai-worker-activity-chat-title">{actor} chat</span>
              <span className="comma-ai-worker-activity-chat-messages">
                {messages.map((message) => (
                  <span
                    className="comma-ai-worker-activity-chat-message"
                    data-sender={message.sender === actor ? "worker" : "router"}
                    key={message.id}
                  >
                    <span className="comma-ai-worker-activity-chat-sender">
                      {message.sender}
                    </span>
                    <span className="comma-ai-worker-activity-chat-content">
                      {message.content}
                    </span>
                  </span>
                ))}
              </span>
            </span>
          }
        >
          <AriaButton
            aria-label={accessibleLabel}
            className="comma-ai-worker-activity-trigger"
            data-interactive="true"
          >
            {workerCopy}
          </AriaButton>
        </Tooltip>
      ) : (
        <span
          aria-label={accessibleLabel}
          className="comma-ai-worker-activity-trigger"
          role={status === "failed" ? "alert" : "status"}
        >
          {workerCopy}
        </span>
      )}
    </div>
  );
}
