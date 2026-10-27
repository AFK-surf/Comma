import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
} from "react";
import { createPortal } from "react-dom";
import { Button as AriaButton } from "react-aria-components";
import { spacing } from "../../tokens";
import {
  clearContextSelectionHighlight,
  paintContextSelectionHighlight,
  snapshotLiveTextSelection,
} from "../menu/preserveTextSelection";
import { cx, isImeKeyEvent } from "../utils";
import {
  selectionActionBar,
  selectionActionBarAction,
  selectionActionBarExcerpt,
  selectionActionBarReply,
  selectionActionBarReplyError,
  selectionActionBarReplyInput,
  selectionActionBarReplyRow,
  selectionActionBarKey,
  selectionActionBarKeys,
  selectionActionBarLabel,
  selectionActionBarSeparator,
  selectionActionBarWideKey,
} from "./styles";

/** Viewport-space rect the bar points at — a `Range.getBoundingClientRect()`. */
export interface SelectionActionBarAnchor {
  bottom: number;
  left: number;
  right: number;
  top: number;
}

export interface SelectionActionBarAction {
  id: string;
  label: string;
  onPress: () => void;
  /** Rendered as keycaps, e.g. `["⌘", "L"]`. */
  shortcut?: readonly string[];
}

/** Which way the selection was drawn; the bar arrives along that path. */
export type SelectionActionBarDirection = "forward" | "backward" | "none";

/**
 * A field of its own under the selected text: what the person types there is
 * sent with the selection as its quote, without touching the main draft.
 */
export interface SelectionActionBarReply {
  /** The selected text, shown above the field. */
  excerpt: string;
  /** Shown under the field when a submitted reply was refused. */
  failedLabel: string;
  /** Pressing outside the bar, or Escape in the field. */
  onDismiss: () => void;
  /**
   * The field takes focus. The page selection moves into the field with it,
   * so the owner must keep the selection's text and anchor from here on.
   */
  onEngage: () => void;
  /**
   * Sends the reply. A promise keeps the field's text until it settles: it is
   * cleared when the promise resolves and kept, with `failedLabel`, when it
   * rejects.
   */
  onSubmit: (text: string) => PromiseLike<unknown> | undefined;
  /**
   * The field's text whenever it changes, so an action pressed while the
   * person is typing (such as quoting the selection) can carry it along.
   */
  onTextChange?: (text: string) => void;
  placeholder: string;
}

export interface SelectionActionBarProps {
  actions: readonly SelectionActionBarAction[];
  anchor: SelectionActionBarAnchor | null;
  ariaLabel: string;
  className?: string;
  /** Defaults to "none" — appearing in place, with no travel. */
  direction?: SelectionActionBarDirection;
  reply?: SelectionActionBarReply;
}

/** Gap between the anchored selection and the bar, both above and below. */
const ANCHOR_GAP = spacing.md;
/** Keeps the bar off the very edge of the window when a selection runs wide. */
const VIEWPORT_INSET = spacing.md;

type Placement = { left: number; top: number };

/** Whether any part of the anchored selection is still on screen. */
const anchorOnScreen = (
  anchor: SelectionActionBarAnchor,
  viewport: { height: number; width: number }
) =>
  anchor.bottom > 0 &&
  anchor.top < viewport.height &&
  anchor.right > 0 &&
  anchor.left < viewport.width;

/**
 * Pressing the bar must not collapse the selection it acts on: the collapse
 * would take the bar down (and with it the pending press) before the pointer
 * ever came back up.
 */
const keepSelection = (event: MouseEvent) => {
  // The reply field is the one place a press must land: focusing it is how
  // the person starts typing.
  if (event.target instanceof HTMLTextAreaElement) return;
  event.preventDefault();
};

const clamp = (value: number, min: number, max: number) =>
  Math.min(Math.max(value, min), max);

const placeBar = (
  anchor: SelectionActionBarAnchor,
  size: { height: number; width: number },
  viewport: { height: number; width: number }
): { placement: Placement; side: "top" | "bottom" } | null => {
  // A selection scrolled out of view has nothing to point at; parking the bar
  // at the viewport edge would leave it anchored to empty space.
  if (!anchorOnScreen(anchor, viewport)) return null;

  const left = clamp(
    (anchor.left + anchor.right) / 2 - size.width / 2,
    VIEWPORT_INSET,
    Math.max(VIEWPORT_INSET, viewport.width - size.width - VIEWPORT_INSET)
  );
  const above = anchor.top - ANCHOR_GAP - size.height;
  // Above is the resting side: it never covers the text the user just read.
  // Only a selection that starts too near the top edge flips below it.
  if (above >= VIEWPORT_INSET && above + size.height <= viewport.height) {
    return { placement: { left, top: above }, side: "top" };
  }
  const below = anchor.bottom + ANCHOR_GAP;
  return {
    placement: {
      left,
      top: clamp(
        below,
        VIEWPORT_INSET,
        Math.max(VIEWPORT_INSET, viewport.height - size.height - VIEWPORT_INSET)
      ),
    },
    side: "bottom",
  };
};

/**
 * A floating action pill anchored to a text selection. It renders in a body
 * portal so scroll containers cannot clip it, and it swallows pointer-down so
 * pressing an action never collapses the selection it acts on.
 */
export const SelectionActionBar = memo(function SelectionActionBar({
  actions,
  anchor,
  ariaLabel,
  className,
  direction = "none",
  reply,
}: SelectionActionBarProps) {
  const barRef = useRef<HTMLDivElement | null>(null);
  const [replyText, setReplyText] = useState("");
  const [replyStatus, setReplyStatus] = useState<"idle" | "sending" | "failed">("idle");
  // The selection the field took focus from, painted as a highlight while
  // the real selection sits in the field.
  const replyHighlightRef = useRef<Highlight | null>(null);
  const replyOpen = Boolean(anchor && reply);
  const onDismiss = reply?.onDismiss;
  const [layout, setLayout] = useState<{
    placement: Placement;
    side: "top" | "bottom";
  }>();
  const actionsKey = actions
    .map(
      (action) => `${action.id}\u0000${action.label}\u0000${action.shortcut?.join("")}`
    )
    .join("\u0001")
    .concat("\u0002", reply?.excerpt ?? "", "\u0002", replyStatus);
  // A callback ref, not an effect: the bar mounts and unmounts with the
  // anchor, so the listener has to follow the element rather than the
  // component's own lifetime.
  const attachBar = useCallback((element: HTMLDivElement | null) => {
    barRef.current?.removeEventListener("mousedown", keepSelection);
    barRef.current = element;
    element?.addEventListener("mousedown", keepSelection);
  }, []);

  // A new selection, or the bar going away, starts the field over, and a
  // reply still being sent for the old one no longer writes to it.
  const replySubmissionRef = useRef(0);
  const replyExcerpt = replyOpen ? reply?.excerpt : undefined;
  useEffect(() => {
    replySubmissionRef.current += 1;
    setReplyText("");
    setReplyStatus("idle");
    clearContextSelectionHighlight(replyHighlightRef.current);
    replyHighlightRef.current = null;
  }, [replyExcerpt]);
  // Reported for each selection too: a field emptied while no owner listened
  // must not leave the next selection's owner with the old text.
  const onTextChange = reply?.onTextChange;
  useEffect(() => {
    onTextChange?.(replyText);
  }, [onTextChange, replyExcerpt, replyText]);
  useEffect(
    () => () => {
      clearContextSelectionHighlight(replyHighlightRef.current);
      replyHighlightRef.current = null;
    },
    []
  );

  // Pressing anywhere else puts a reply in progress away.
  useEffect(() => {
    if (!replyOpen || !onDismiss) return undefined;
    const handlePointerDown = (event: PointerEvent) => {
      if (event.target instanceof Node && barRef.current?.contains(event.target))
        return;
      onDismiss();
    };
    document.addEventListener("pointerdown", handlePointerDown, true);
    return () => document.removeEventListener("pointerdown", handlePointerDown, true);
  }, [onDismiss, replyOpen]);

  const engageReply = useCallback(() => {
    if (!reply) return;
    if (!replyHighlightRef.current) {
      replyHighlightRef.current = paintContextSelectionHighlight(
        snapshotLiveTextSelection()
      );
    }
    reply.onEngage();
  }, [reply]);

  const handleReplyKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (!reply) return;
    if (event.key === "Escape") {
      event.preventDefault();
      reply.onDismiss();
      return;
    }
    if (event.key !== "Enter" || event.shiftKey || isImeKeyEvent(event.nativeEvent)) {
      return;
    }
    event.preventDefault();
    const text = replyText.trim();
    if (!text || replyStatus === "sending") return;
    const submission = ++replySubmissionRef.current;
    const fail = () => {
      if (replySubmissionRef.current === submission) setReplyStatus("failed");
    };
    const succeed = () => {
      if (replySubmissionRef.current !== submission) return;
      setReplyText("");
      setReplyStatus("idle");
    };
    let result: PromiseLike<unknown> | undefined;
    try {
      result = reply.onSubmit(text);
    } catch {
      fail();
      return;
    }
    if (!result) {
      succeed();
      return;
    }
    setReplyStatus("sending");
    result.then(succeed, fail);
  };

  // Measure after paint: the pill's width depends on the label and keycaps,
  // which are locale-dependent, so the placement math cannot be predicted.
  useLayoutEffect(() => {
    const bar = barRef.current;
    if (!anchor || !bar) {
      setLayout(undefined);
      return;
    }

    // Layout metrics, not the painted rect: the bar is measured while its
    // enter transition still holds it at a reduced scale, and a scaled
    // getBoundingClientRect would place it a pixel off its resting position.
    const next = placeBar(
      anchor,
      { height: bar.offsetHeight, width: bar.offsetWidth },
      { height: window.innerHeight, width: window.innerWidth }
    );
    setLayout((current) =>
      current &&
      next &&
      current.side === next.side &&
      current.placement.left === next.placement.left &&
      current.placement.top === next.placement.top
        ? current
        : (next ?? undefined)
    );
    // The action list is measured through the bar's own box, so a fresh array
    // with the same contents must not re-trigger placement. A question that
    // wraps onto another line grows the bar, which is placed again.
  }, [anchor, actionsKey, replyText]);

  if (!anchor || actions.length === 0 || typeof document === "undefined") {
    return null;
  }

  const actionButtons = actions.map((action, index) => (
    <div className="contents" key={action.id}>
      {index > 0 ? <span aria-hidden className={selectionActionBarSeparator} /> : null}
      <AriaButton
        className={selectionActionBarAction}
        data-action-id={action.id}
        onPress={action.onPress}
      >
        <span className={selectionActionBarLabel}>{action.label}</span>
        {action.shortcut?.length ? (
          <span
            aria-hidden
            className={selectionActionBarKeys}
            data-slot="selection-action-bar-keys"
          >
            {action.shortcut.map((key, keyIndex) => (
              <kbd
                className={
                  key.length > 1 ? selectionActionBarWideKey : selectionActionBarKey
                }
                // A shortcut can repeat a key, so position is part of identity.
                key={`${key}-${keyIndex}`}
              >
                {key}
              </kbd>
            ))}
          </span>
        ) : null}
      </AriaButton>
    </div>
  ));

  return createPortal(
    <div
      aria-hidden={layout ? undefined : true}
      aria-label={ariaLabel}
      className={cx(selectionActionBar, reply && selectionActionBarReply, className)}
      data-direction={direction}
      data-placement={layout?.side}
      data-slot="selection-action-bar"
      // Hidden until measured so the first paint never lands at 0,0.
      data-visible={layout ? "true" : undefined}
      ref={attachBar}
      role="toolbar"
      style={{ left: layout?.placement.left ?? 0, top: layout?.placement.top ?? 0 }}
      tabIndex={-1}
    >
      {reply ? (
        <>
          <p
            className={selectionActionBarExcerpt}
            data-slot="selection-action-bar-excerpt"
          >
            {reply.excerpt}
          </p>
          <div className={selectionActionBarReplyRow}>
            <textarea
              aria-label={reply.placeholder}
              className={selectionActionBarReplyInput}
              aria-busy={replyStatus === "sending" || undefined}
              onChange={(event) => {
                setReplyText(event.target.value);
                if (replyStatus === "failed") setReplyStatus("idle");
              }}
              onFocus={engageReply}
              onKeyDown={handleReplyKeyDown}
              onPointerDown={engageReply}
              placeholder={reply.placeholder}
              rows={1}
              value={replyText}
            />
            {actionButtons}
          </div>
          {replyStatus === "failed" ? (
            <p className={selectionActionBarReplyError} role="alert">
              {reply.failedLabel}
            </p>
          ) : null}
        </>
      ) : (
        actionButtons
      )}
    </div>,
    document.body
  );
});
