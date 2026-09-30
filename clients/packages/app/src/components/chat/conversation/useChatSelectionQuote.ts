import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import {
  resolveChatSelectionQuote,
  type ChatSelectionAnchor,
  type ChatSelectionQuote,
} from "./chatMessageContextMenu";

const EDITABLE_SELECTOR = 'input, textarea, [contenteditable="true"]';

/**
 * A gesture that lands in an editor is never a quote: the composer owns that
 * selection. Skipping those keeps every keystroke out of the resolver, which
 * would otherwise walk the DOM once per character typed.
 */
const isEditableTarget = (target: EventTarget | null) =>
  target instanceof Element && target.closest(EDITABLE_SELECTOR) !== null;

const sameAnchor = (left: ChatSelectionAnchor, right: ChatSelectionAnchor) =>
  left.bottom === right.bottom &&
  left.left === right.left &&
  left.right === right.right &&
  left.top === right.top;

/**
 * A double- or triple-click selects a word or line outright. The DOM still
 * reports it anchor-before-focus, but the pointer never travelled, so the bar
 * must not pretend it did. `mousedown` carries the click count and lands
 * before the settling `pointerup`, which is the ordering this needs.
 */
const isMultiClick = (event: MouseEvent) => event.detail >= 2;

/**
 * Tracks the chat-message text selection the quote action operates on.
 *
 * The bar is raised only once a gesture settles (pointerup / keyup): the
 * `selectionchange` stream fires on every mouse move during a drag, so
 * following it directly would make the bar chase the cursor. It still listens
 * to `selectionchange` for the one thing that must be immediate — a collapsed
 * selection has to take the bar down with it.
 */
export function useChatSelectionQuote(rootRef: RefObject<HTMLElement | null>) {
  const [selection, setSelection] = useState<ChatSelectionQuote | null>(null);
  const multiClickRef = useRef(false);

  const sync = useCallback(() => {
    const root = rootRef.current;
    if (!root) {
      setSelection(null);
      return;
    }

    setSelection((current) => {
      const resolved = resolveChatSelectionQuote(root);
      if (!resolved) return current === null ? current : null;
      const next = multiClickRef.current
        ? { ...resolved, direction: "none" as const }
        : resolved;
      // Identity is load-bearing: it feeds the bar's measure effect, so an
      // unchanged selection must not re-trigger placement every scroll frame.
      return current &&
        current.text === next.text &&
        current.direction === next.direction &&
        sameAnchor(current.anchor, next.anchor)
        ? current
        : next;
    });
  }, [rootRef]);

  const clear = useCallback(() => setSelection(null), []);

  useEffect(() => {
    const handleSelectionChange = () => {
      const active = window.getSelection();
      if (!active || active.isCollapsed || active.rangeCount === 0) setSelection(null);
    };

    const handleSettled = (event: Event) => {
      if (isEditableTarget(event.target)) return;
      sync();
    };
    const handleMouseDown = (event: MouseEvent) => {
      multiClickRef.current = isMultiClick(event);
    };
    // Keyboard selections travel without a pointer, so their direction is
    // whatever the DOM reports.
    const handleKeyDown = () => {
      multiClickRef.current = false;
    };

    document.addEventListener("selectionchange", handleSelectionChange);
    document.addEventListener("mousedown", handleMouseDown, true);
    document.addEventListener("keydown", handleKeyDown, true);
    document.addEventListener("pointerup", handleSettled);
    document.addEventListener("keyup", handleSettled);
    return () => {
      document.removeEventListener("selectionchange", handleSelectionChange);
      document.removeEventListener("mousedown", handleMouseDown, true);
      document.removeEventListener("keydown", handleKeyDown, true);
      document.removeEventListener("pointerup", handleSettled);
      document.removeEventListener("keyup", handleSettled);
    };
  }, [sync]);

  // The anchor is viewport-space, so it goes stale the moment the thread
  // scrolls under it. Re-measure on a frame boundary while the bar is up.
  useEffect(() => {
    if (!selection) return undefined;

    let frame = 0;
    const schedule = () => {
      if (frame !== 0) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        sync();
      });
    };

    window.addEventListener("resize", schedule);
    document.addEventListener("scroll", schedule, true);
    return () => {
      if (frame !== 0) cancelAnimationFrame(frame);
      window.removeEventListener("resize", schedule);
      document.removeEventListener("scroll", schedule, true);
    };
  }, [selection, sync]);

  return { clear, selection };
}
