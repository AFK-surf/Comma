import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { motionDistance, motionDuration, motionEasing } from "@comma/ui/tokens";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type { ChatAssistantDraft, ChatMessage } from "@comma/core/chat";
import { MessageRow } from "../rows/MessageRow";
import {
  messageRelationships,
  type RowRelationshipProps,
} from "./messageRelationships";
import {
  replyThreadDraft,
  replyThreadMessages,
  type ReplyThreadSelection,
} from "./replyThread";

type RowProps = Pick<
  Parameters<typeof MessageRow>[0],
  | "groupId"
  | "live"
  | "onDiscard"
  | "onOpenConversationRef"
  | "onPreviewLocalFile"
  | "onRetry"
  | "workspaceId"
>;

type ReplyThreadOverlayProps = {
  assistantDraft: ChatAssistantDraft | undefined;
  messages: readonly ChatMessage[];
  onExit: () => void;
  rows: RowProps;
  selection: ReplyThreadSelection | undefined;
};

/**
 * iMessage-style reply thread. The thread's messages leave their places in
 * the transcript and gather above the composer over a dimmed transcript;
 * closing sends each one back. The layer stays mounted through that exit.
 */
export function ReplyThreadOverlay({ selection, ...props }: ReplyThreadOverlayProps) {
  const [presented, setPresented] = useState(selection);
  // A thread handed over to the next one slides out while the next slides in.
  const [leaving, setLeaving] = useState<string>();
  if (selection && selection.rootId !== presented?.rootId) {
    if (presented && selection.advance) setLeaving(presented.rootId);
    setPresented(selection);
  }
  const closed = useCallback(() => setPresented(undefined), []);
  const left = useCallback(() => setLeaving(undefined), []);
  // Layers mounted now. The transcript stays inert while any is up; a count
  // shared here, because two layers can unmount in one commit and each would
  // still find the other in the DOM.
  const inertHolds = useRef(0);
  const layers = [];
  if (presented) {
    const open = selection?.rootId === presented.rootId;
    layers.push(
      <ReplyThreadLayer
        key={presented.rootId}
        {...props}
        advance={presented.advance === true}
        closing={!open}
        inertHolds={inertHolds}
        leaving={false}
        onClosed={closed}
        progress={open ? selection.progress : undefined}
        rootId={presented.rootId}
      />
    );
  }
  if (leaving !== undefined && leaving !== presented?.rootId) {
    layers.push(
      <ReplyThreadLayer
        key={leaving}
        {...props}
        advance={false}
        closing={false}
        inertHolds={inertHolds}
        leaving
        onClosed={left}
        progress={undefined}
        rootId={leaving}
      />
    );
  }
  // One keyed list, so a layer keeps its identity when it starts leaving.
  return layers.length > 0 ? <>{layers}</> : null;
}

const TRANSCRIPT_COLUMN = ".comma-chat-scroll-viewport .comma-chat-column";
const OVERLAY_VIEWPORT = ".comma-chat-reply-thread-viewport";

function ReplyThreadLayer({
  advance,
  assistantDraft,
  closing,
  inertHolds,
  leaving,
  messages,
  onClosed,
  onExit,
  progress,
  rootId,
  rows,
}: Omit<ReplyThreadOverlayProps, "selection"> & {
  /** Enters sideways, taking over from the thread before it. */
  advance: boolean;
  closing: boolean;
  /** Layers of this overlay holding the transcript inert. */
  inertHolds: { current: number };
  /** Slides out sideways for the thread taking over; the backdrop stays. */
  leaving: boolean;
  onClosed: () => void;
  progress: { index: number; total: number } | undefined;
  rootId: string;
}) {
  const messagesApi = useCommaMessages();
  const layerRef = useRef<HTMLElement>(null);
  const columnRef = useRef<HTMLDivElement>(null);
  const { draftId, thread } = useMemo(() => {
    const members = replyThreadMessages(messages, rootId);
    const draft = replyThreadDraft(assistantDraft, members);
    return {
      draftId: draft?.messageId,
      thread: draft ? [...members, draft] : members,
    };
  }, [assistantDraft, messages, rootId]);
  const relationships = useMemo(() => {
    const { positions } = messageRelationships(thread);
    const tails = new Set(
      thread
        .filter((message, index) => {
          const next = thread[index + 1];
          return (
            !next ||
            message.role !== next.role ||
            message.platformSource !== next.platformSource ||
            (message.role === "user" && message.createdBy !== next.createdBy)
          );
        })
        .map((message) => message.messageId)
    );
    return { positions, tails };
  }, [thread]);
  const rowRelationship = (messageId: string): RowRelationshipProps => {
    const position = relationships.positions.get(messageId);
    return {
      bubbleTail: relationships.tails.has(messageId),
      groupFirst: position?.first,
      groupLast: position?.last,
    };
  };

  // Transcript rows this layer stands in for, hidden while their copies are
  // up here and shown again once the copies have flown back.
  const hidden = useRef(new Map<string, HTMLElement>());
  const placed = useRef(new Set<string>());
  // The streaming answer shown last pass. The committed message that replaces
  // it has a new id, but it is the same answer and must not enter again.
  const shownDraftId = useRef<string | undefined>(undefined);
  const restoreSources = useCallback(() => {
    for (const source of hidden.current.values()) source.style.visibility = "";
    hidden.current.clear();
  }, []);

  useLayoutEffect(() => {
    const layer = layerRef.current;
    const transcript = layer?.parentElement?.querySelector<HTMLElement>(
      ".comma-chat-scroll-viewport"
    );
    if (!layer || !transcript) return;
    inertHolds.current += 1;
    transcript.inert = true;
    return () => {
      // A thread taking over keeps the transcript inert.
      inertHolds.current -= 1;
      if (inertHolds.current === 0) transcript.inert = false;
      restoreSources();
    };
  }, [inertHolds, restoreSources]);

  // Each copy enters once: from its transcript row when that row is in view,
  // otherwise rising into place. Later arrivals (the reader's reply, the
  // Agent's answer) only rise in.
  useLayoutEffect(() => {
    const layer = layerRef.current;
    const column = columnRef.current;
    if (!layer || !column || closing || leaving) return;
    const firstPass = placed.current.size === 0;
    let handoff =
      shownDraftId.current !== undefined &&
      shownDraftId.current !== draftId &&
      !thread.some((message) => message.messageId === shownDraftId.current);
    shownDraftId.current = draftId;
    const viewport = layer.querySelector<HTMLElement>(OVERLAY_VIEWPORT);
    if (viewport) viewport.scrollTop = viewport.scrollHeight;
    const reduced = prefersReducedMotion();
    const bounds = layer.getBoundingClientRect();
    for (const row of column.querySelectorAll<HTMLElement>(
      "article[data-message-id]"
    )) {
      const id = row.dataset.messageId!;
      if (placed.current.has(id)) continue;
      placed.current.add(id);
      const source = transcriptRow(layer, id);
      if (source && !hidden.current.has(id)) {
        hidden.current.set(id, source);
      }
      if (source) source.style.visibility = "hidden";
      if (
        handoff &&
        thread.find((message) => message.messageId === id)?.role === "assistant"
      ) {
        handoff = false;
        continue;
      }
      const from = source?.getBoundingClientRect();
      const to = row.getBoundingClientRect();
      if (firstPass && advance) {
        animate(
          row,
          [
            {
              opacity: 0,
              transform: reduced
                ? "none"
                : `translateX(${motionDistance.replyThreadAdvance}px)`,
            },
            { opacity: 1, transform: "none" },
          ],
          { duration: motionDuration.replyThreadEnter, easing: motionEasing.drawer }
        );
      } else if (firstPass && !reduced && from && intersects(from, bounds)) {
        animate(
          row,
          [
            {
              transform: `translate(${from.left - to.left}px, ${from.top - to.top}px)`,
            },
            { transform: "none" },
          ],
          { duration: motionDuration.replyThreadEnter, easing: motionEasing.drawer }
        );
      } else {
        animate(
          row,
          [
            {
              opacity: 0,
              transform: reduced
                ? "none"
                : `translateY(${motionDistance.revealItem}px)`,
            },
            { opacity: 1, transform: "none" },
          ],
          {
            duration: motionDuration.replyThreadEnter,
            easing: motionEasing.smoothOut,
          }
        );
      }
    }
  }, [advance, closing, draftId, leaving, thread]);

  // Handing over slides every copy out sideways; the rows behind the backdrop
  // show again once it is gone.
  useLayoutEffect(() => {
    if (!leaving) return;
    const column = columnRef.current;
    if (!column) {
      onClosed();
      return;
    }
    const reduced = prefersReducedMotion();
    const animations = [
      ...column.querySelectorAll<HTMLElement>("article[data-message-id]"),
    ].map((row) =>
      animate(
        row,
        [
          { opacity: 1, transform: "none" },
          {
            opacity: 0,
            transform: reduced
              ? "none"
              : `translateX(${-motionDistance.replyThreadAdvance}px)`,
          },
        ],
        {
          duration: motionDuration.replyThreadExit,
          easing: motionEasing.drawer,
          fill: "forwards",
        }
      )
    );
    let cancelled = false;
    void Promise.allSettled(animations).then(() => {
      if (!cancelled) onClosed();
    });
    return () => {
      cancelled = true;
    };
  }, [leaving, onClosed]);

  // Closing sends each copy back to its row, then shows the rows again.
  useLayoutEffect(() => {
    if (!closing) return;
    const layer = layerRef.current;
    const column = columnRef.current;
    if (!layer || !column) {
      onClosed();
      return;
    }
    const reduced = prefersReducedMotion();
    const bounds = layer.getBoundingClientRect();
    const animations = [
      ...column.querySelectorAll<HTMLElement>("article[data-message-id]"),
    ].map((row) => {
      const source = transcriptRow(layer, row.dataset.messageId!);
      const to = source?.getBoundingClientRect();
      const from = row.getBoundingClientRect();
      const keyframes =
        !reduced && to && intersects(to, bounds)
          ? [
              { transform: "none" },
              {
                transform: `translate(${to.left - from.left}px, ${to.top - from.top}px)`,
              },
            ]
          : [{ opacity: 1 }, { opacity: 0 }];
      return animate(row, keyframes, {
        duration: motionDuration.replyThreadExit,
        easing: motionEasing.drawer,
        fill: "forwards",
      });
    });
    let cancelled = false;
    void Promise.allSettled(animations).then(() => {
      if (cancelled) return;
      restoreSources();
      onClosed();
    });
    return () => {
      cancelled = true;
    };
  }, [closing, onClosed, restoreSources]);

  // The composer keeps keyboard focus while the thread is open, and Escape
  // there closes it; a click on the dimmed space is the pointer's way out.
  useEffect(() => {
    const layer = layerRef.current;
    if (!layer) return;
    const exitOnEmptySpace = (event: globalThis.MouseEvent) => {
      const target = event.target;
      if (
        target instanceof Element &&
        target.closest('article, button, a, [data-slot="scroll-area-scrollbar"]')
      )
        return;
      onExit();
    };
    layer.addEventListener("click", exitOnEmptySpace);
    return () => layer.removeEventListener("click", exitOnEmptySpace);
  }, [onExit]);

  return (
    <section
      aria-label={messagesApi.chat_reply_thread()}
      className="comma-chat-reply-thread"
      data-enter={advance ? "advance" : undefined}
      data-state={leaving ? "leaving" : closing ? "closing" : "open"}
      data-testid="chat-reply-thread"
      ref={layerRef}
    >
      <ScrollArea
        className="min-h-0 flex-1"
        contentClassName="comma-chat-reply-thread-content"
        edgeEffect="mask"
        viewportClassName="comma-chat-reply-thread-viewport"
      >
        <div
          className="comma-chat-column comma-chat-reply-thread-column"
          ref={columnRef}
        >
          {progress ? (
            <output
              aria-label={messagesApi.chat_reply_thread_progress({
                index: progress.index,
                total: progress.total,
              })}
              className="comma-chat-reply-thread-progress"
            >
              {progress.index} / {progress.total}
            </output>
          ) : null}
          {/* Gathered together the messages are visibly one thread: no connectors. */}
          {thread.map((message) => (
            <MessageRow
              key={message.messageId}
              {...rowRelationship(message.messageId)}
              {...rows}
              chainState={undefined}
              message={message}
              referenceMode="link"
              showActions={false}
            />
          ))}
        </div>
      </ScrollArea>
    </section>
  );
}

function transcriptRow(layer: HTMLElement, messageId: string) {
  return (
    layer.parentElement
      ?.querySelector(TRANSCRIPT_COLUMN)
      ?.querySelector<HTMLElement>(
        `article[data-message-id="${CSS.escape(messageId)}"]`
      ) ?? null
  );
}

// Hosts without the Web Animations API (tests, older engines) skip the motion.
function animate(
  row: HTMLElement,
  keyframes: Keyframe[],
  options: KeyframeAnimationOptions
) {
  return typeof row.animate === "function"
    ? row.animate(keyframes, options).finished
    : Promise.resolve();
}

function intersects(rect: DOMRect, bounds: DOMRect) {
  return rect.bottom > bounds.top && rect.top < bounds.bottom && rect.height > 0;
}

function prefersReducedMotion() {
  return (
    typeof window !== "undefined" &&
    window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true
  );
}
