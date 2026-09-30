import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { isReducedMotionEnabled, motionDuration, motionEasing } from "../../tokens";
import { cx } from "../utils";
import {
  taskCardReorderContent,
  taskCardReorderContentDragging,
  taskCardReorderContentYielding,
  taskCardReorderList,
  taskCardReorderSlot,
  taskCardReorderSlotDragging,
} from "./styles";

/** Pointer travel that separates a drag from a click on the card. */
const DRAG_THRESHOLD = 4;
/** Distance from a scrollport edge where a held card starts scrolling it. */
const AUTOSCROLL_EDGE = 56;
/** Peak autoscroll speed, in pixels per frame at the very edge. */
const AUTOSCROLL_MAX_SPEED = 18;
/**
 * How far the card leans sideways at most. Reordering is vertical, so sideways
 * pointer travel only tilts the card toward the hand — asymptotically, never
 * further than the column padding it would get clipped by.
 */
const LEAN_MAX = 12;

type DragState = {
  /** Index the card started from. */
  from: number;
  /** Index it would land on if released now. */
  to: number;
  /** How much room the card takes out of the column while it is lifted. */
  span: number;
};

type ReorderContextValue = {
  drag: DragState | null;
  ids: readonly string[];
  onPointerDown: (id: string, event: ReactPointerEvent<HTMLDivElement>) => void;
  register: (id: string, element: HTMLDivElement | null) => void;
};

const ReorderContext = createContext<ReorderContextValue | null>(null);

export interface TaskCardReorderListProps {
  children: ReactNode;
  className?: string;
  /** Card ids in the order they are rendered. */
  ids: readonly string[];
  /** Receives the full id list in its new order once a card is dropped. */
  onReorder: (ids: string[]) => void;
}

/**
 * Vertical drag-to-reorder within one board column, on three rules:
 *
 * 1. The held card sticks to the hand. It follows the pointer freely — its
 *    transform is written straight to the node each move, nothing else
 *    re-renders — with only a bounded sideways lean, because order is the one
 *    thing the drag can change.
 * 2. Crossing a neighbour's middle claims its spot. The slot the card came
 *    out of paints itself as an empty well; covering less than half of a
 *    neighbour is just hovering over it, and once the card's leading edge
 *    passes the neighbour's middle, that neighbour slides over into the
 *    vacated spot — the drop index simply follows.
 * 3. Release hands the card to the layout. Every card is measured where it is
 *    actually drawn, the order commits, and each one animates from there into
 *    its slot — the card visibly falls into the well, with no jump anywhere.
 */
export function TaskCardReorderList({
  children,
  className,
  ids,
  onReorder,
}: TaskCardReorderListProps) {
  const listRef = useRef<HTMLDivElement>(null);
  const itemsRef = useRef(new Map<string, HTMLDivElement>());
  const [drag, setDrag] = useState<DragState | null>(null);
  /** Slot geometry captured at lift, so pointer math never re-reads layout. */
  const slotsRef = useRef<{ height: number; id: string; top: number }[]>([]);
  const gestureRef = useRef<{
    from: number;
    id: string;
    /** Ordered ids this gesture belongs to; a live sequence change cancels it. */
    ids: string[];
    lifted: boolean;
    /** Scroll range at lift; the held card's own travel must not extend it. */
    maxScrollTop: number;
    pointerId: number;
    pointerX: number;
    pointerY: number;
    scrollTop: number;
    startX: number;
    startY: number;
    to: number;
    viewport: HTMLElement | null;
  } | null>(null);
  const autoScrollRef = useRef(0);
  /** Where every card was drawn at drop time, replayed as the settle motion. */
  const settleRef = useRef<Map<string, { x: number; y: number }> | null>(null);
  /** True from the moment a lift happens until the click it produces is eaten. */
  const suppressClickRef = useRef(false);
  const idsRef = useRef(ids);
  idsRef.current = ids;
  const onReorderRef = useRef(onReorder);
  onReorderRef.current = onReorder;

  const register = useCallback((id: string, element: HTMLDivElement | null) => {
    if (element) itemsRef.current.set(id, element);
    else itemsRef.current.delete(id);
  }, []);

  /** The moving layer inside a slot: what the pointer drives and FLIP settles. */
  const carrierOf = (id: string) =>
    (itemsRef.current.get(id)?.firstElementChild as HTMLElement | null) ?? null;

  const stopAutoScroll = useCallback(() => {
    if (!autoScrollRef.current) return;
    cancelAnimationFrame(autoScrollRef.current);
    autoScrollRef.current = 0;
  }, []);

  /**
   * Draws the held card at the hand and re-derives the drop slot. The
   * transform is written to the node rather than rendered — the pointer moves
   * every frame, and only the drop index is anything the column reacts to.
   */
  const applyPointer = useCallback(() => {
    const gesture = gestureRef.current;
    const slots = slotsRef.current;
    if (!gesture?.lifted || slots.length === 0) return;
    const scrolled = (gesture.viewport?.scrollTop ?? 0) - gesture.scrollTop;
    const travelY = gesture.pointerY - gesture.startY + scrolled;
    const lean = leanOf(gesture.pointerX - gesture.startX);
    const carrier = carrierOf(gesture.id);
    if (carrier) carrier.style.transform = `translate(${lean}px, ${travelY}px)`;

    // A neighbour yields when the held card's leading edge crosses its middle:
    // covering less than half of it is just hovering, past half the card has
    // claimed the spot — the neighbour slides over to fill the vacated one and
    // the drop index follows.
    const slot = slots[gesture.from]!;
    const top = slot.top + travelY;
    const bottom = top + slot.height;
    let to = gesture.from;
    if (travelY > 0) {
      for (let index = gesture.from + 1; index < slots.length; index += 1) {
        const middle = slots[index]!.top + slots[index]!.height / 2;
        if (bottom <= middle) break;
        to = index;
      }
    } else if (travelY < 0) {
      for (let index = gesture.from - 1; index >= 0; index -= 1) {
        const middle = slots[index]!.top + slots[index]!.height / 2;
        if (top >= middle) break;
        to = index;
      }
    }
    if (to === gesture.to) return;
    gesture.to = to;
    setDrag({ from: gesture.from, span: spanOf(slots, gesture.from), to });
  }, []);

  const runAutoScroll = useCallback(() => {
    const gesture = gestureRef.current;
    const viewport = gesture?.viewport;
    if (!gesture?.lifted || !viewport) return;
    const bounds = viewport.getBoundingClientRect();
    const overTop = bounds.top + AUTOSCROLL_EDGE - gesture.pointerY;
    const overBottom = gesture.pointerY - (bounds.bottom - AUTOSCROLL_EDGE);
    const speed =
      overTop > 0
        ? -Math.min(overTop, AUTOSCROLL_EDGE)
        : overBottom > 0
          ? Math.min(overBottom, AUTOSCROLL_EDGE)
          : 0;
    if (speed !== 0) {
      viewport.scrollTop = Math.min(
        viewport.scrollTop + (speed / AUTOSCROLL_EDGE) * AUTOSCROLL_MAX_SPEED,
        gesture.maxScrollTop
      );
      applyPointer();
    }
    autoScrollRef.current = requestAnimationFrame(runAutoScroll);
  }, [applyPointer]);

  /**
   * Hands the cards over from the hand to the layout: every card is measured
   * where it is drawn, then animated from there into the slot the new order
   * gives it.
   */
  const endGesture = useCallback(
    (commit: boolean) => {
      const gesture = gestureRef.current;
      gestureRef.current = null;
      stopAutoScroll();
      if (!gesture?.lifted) return;
      const idsUnchanged = sameIds(gesture.ids, idsRef.current);
      const drawn = idsUnchanged ? new Map<string, { x: number; y: number }>() : null;
      if (drawn) {
        for (const id of gesture.ids) {
          const carrier = carrierOf(id);
          if (!carrier) continue;
          const rect = carrier.getBoundingClientRect();
          drawn.set(id, { x: rect.left, y: rect.top });
        }
      }
      const held = carrierOf(gesture.id);
      if (held) held.style.transform = "";
      settleRef.current = drawn;
      setDrag(null);
      if (commit && idsUnchanged && gesture.to !== gesture.from) {
        const next = [...gesture.ids];
        const [moved] = next.splice(gesture.from, 1);
        if (moved) next.splice(gesture.to, 0, moved);
        onReorderRef.current(next);
      }
    },
    [stopAutoScroll]
  );

  const onPointerDown = useCallback(
    (id: string, event: ReactPointerEvent<HTMLDivElement>) => {
      // One card at a time: a second finger during a drag is ignored rather
      // than teleporting the card to it.
      if (event.button !== 0 || gestureRef.current) return;
      const from = idsRef.current.indexOf(id);
      if (from < 0) return;
      suppressClickRef.current = false;
      const viewport = listRef.current?.closest<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      );
      gestureRef.current = {
        from,
        id,
        ids: [...idsRef.current],
        lifted: false,
        maxScrollTop: viewport ? viewport.scrollHeight - viewport.clientHeight : 0,
        pointerId: event.pointerId,
        pointerX: event.clientX,
        pointerY: event.clientY,
        scrollTop: viewport?.scrollTop ?? 0,
        startX: event.clientX,
        startY: event.clientY,
        to: from,
        viewport: viewport ?? null,
      };
    },
    []
  );

  // Product projections are live. The captured slot indices only describe the
  // exact ID sequence at pointer down; if that sequence changes, cancel before
  // paint rather than applying stale indices to a different set of cards.
  useLayoutEffect(() => {
    const gesture = gestureRef.current;
    if (!gesture || sameIds(gesture.ids, ids)) return;
    endGesture(false);
  }, [endGesture, ids]);

  useEffect(() => {
    const handleMove = (event: PointerEvent) => {
      const gesture = gestureRef.current;
      if (!gesture || event.pointerId !== gesture.pointerId) return;
      gesture.pointerX = event.clientX;
      gesture.pointerY = event.clientY;
      if (!gesture.lifted) {
        if (Math.abs(event.clientY - gesture.startY) < DRAG_THRESHOLD) return;
        slotsRef.current = idsRef.current.map((id) => {
          const element = itemsRef.current.get(id);
          return {
            height: element?.offsetHeight ?? 0,
            id,
            top: element?.offsetTop ?? 0,
          };
        });
        gesture.lifted = true;
        suppressClickRef.current = true;
        // The well shows up the moment the card lifts.
        setDrag({
          from: gesture.from,
          span: spanOf(slotsRef.current, gesture.from),
          to: gesture.from,
        });
        autoScrollRef.current = requestAnimationFrame(runAutoScroll);
      }
      // A lifted card owns the pointer: no text selection, no scroll chaining.
      event.preventDefault();
      applyPointer();
    };
    const handleUp = (event: PointerEvent) => {
      if (event.pointerId !== gestureRef.current?.pointerId) return;
      endGesture(true);
    };
    const handleCancel = (event: PointerEvent) => {
      if (event.pointerId !== gestureRef.current?.pointerId) return;
      endGesture(false);
    };
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || !gestureRef.current?.lifted) return;
      event.preventDefault();
      endGesture(false);
    };
    window.addEventListener("pointermove", handleMove, { passive: false });
    window.addEventListener("pointerup", handleUp);
    window.addEventListener("pointercancel", handleCancel);
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("pointermove", handleMove);
      window.removeEventListener("pointerup", handleUp);
      window.removeEventListener("pointercancel", handleCancel);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [applyPointer, endGesture, runAutoScroll]);

  useEffect(() => stopAutoScroll, [stopAutoScroll]);

  useLayoutEffect(() => {
    const drawn = settleRef.current;
    settleRef.current = null;
    if (!drawn || isReducedMotionEnabled()) return;
    for (const [id, before] of drawn) {
      const carrier = carrierOf(id);
      if (!carrier) continue;
      const rect = carrier.getBoundingClientRect();
      const deltaX = before.x - rect.left;
      const deltaY = before.y - rect.top;
      if (Math.abs(deltaX) < 1 && Math.abs(deltaY) < 1) continue;
      carrier.animate(
        [
          { transform: `translate(${deltaX}px, ${deltaY}px)` },
          { transform: "translate(0, 0)" },
        ],
        {
          duration: motionDuration.spatialMove,
          easing: motionEasing.surfaceSmoothOut,
        }
      );
    }
  });

  const context = useMemo<ReorderContextValue>(
    () => ({ drag, ids, onPointerDown, register }),
    [drag, ids, onPointerDown, register]
  );

  return (
    <ReorderContext.Provider value={context}>
      <div
        className={cx(taskCardReorderList, className)}
        data-dragging={drag ? "true" : undefined}
        data-slot="task-card-reorder-list"
        onClickCapture={(event) => {
          if (!suppressClickRef.current) return;
          suppressClickRef.current = false;
          event.preventDefault();
          event.stopPropagation();
        }}
        ref={listRef}
      >
        {children}
      </div>
    </ReorderContext.Provider>
  );
}

export interface TaskCardReorderItemProps {
  children: ReactNode;
  id: string;
}

/** One draggable slot. Renders its card inside the well it can be lifted out of. */
export function TaskCardReorderItem({ children, id }: TaskCardReorderItemProps) {
  const context = useContext(ReorderContext);
  if (!context) throw new Error("TaskCardReorderItem requires TaskCardReorderList");
  const { drag, ids, onPointerDown, register } = context;
  const index = ids.indexOf(id);
  const dragging = drag?.from === index;
  const shift = neighbourShift(drag, index);

  return (
    <div
      className={cx(taskCardReorderSlot, dragging && taskCardReorderSlotDragging)}
      data-dragging={dragging ? "true" : undefined}
      data-slot="task-card-reorder-item"
      onPointerDown={(event) => onPointerDown(id, event)}
      ref={(element) => register(id, element)}
    >
      <div
        className={cx(
          taskCardReorderContent,
          dragging && taskCardReorderContentDragging,
          drag && !dragging && taskCardReorderContentYielding
        )}
        // The held card is drawn straight from the pointer handler and gets no
        // style from React, so a re-render never yanks it out of the hand;
        // only the cards making room for it travel on a curve.
        {...(dragging
          ? {}
          : {
              style: {
                ...(shift ? { transform: `translateY(${shift}px)` } : {}),
                ...(drag
                  ? {
                      transition:
                        "transform var(--motion-duration-spatial-move) var(--motion-easing-surface-smooth-out)",
                    }
                  : {}),
              },
            })}
      >
        {children}
      </div>
    </div>
  );
}

/** How far a card slides to open the well at the index the drop would use. */
function neighbourShift(drag: DragState | null, index: number): number {
  if (!drag || drag.to === drag.from || index === drag.from) return 0;
  if (drag.to > drag.from && index > drag.from && index <= drag.to) return -drag.span;
  if (drag.to < drag.from && index >= drag.to && index < drag.from) return drag.span;
  return 0;
}

/** The room the held card takes out of the column: its height plus one gap. */
function spanOf(
  slots: readonly { height: number; top: number }[],
  from: number
): number {
  const gap = slots[1] ? slots[1].top - (slots[0]!.top + slots[0]!.height) : 0;
  return slots[from]!.height + gap;
}

/** Sideways travel eases toward LEAN_MAX instead of leaving the column. */
function leanOf(travelX: number): number {
  return (travelX * LEAN_MAX) / (LEAN_MAX + Math.abs(travelX));
}

function sameIds(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((id, index) => id === right[index]);
}

/**
 * Puts a list's cards in the order the user dragged them into. Ids the manual
 * order has not seen — tasks created or moved here since — keep their
 * projection order and lead the list, which is where the default (most
 * recently updated first) would have put them anyway.
 */
export function applyManualOrder<T extends { id: string }>(
  items: readonly T[],
  order: readonly string[] | undefined
): T[];
export function applyManualOrder<T>(
  items: readonly T[],
  order: readonly string[] | undefined,
  idOf: (item: T) => string
): T[];
export function applyManualOrder<T>(
  items: readonly T[],
  order: readonly string[] | undefined,
  idOf: (item: T) => string = (item) => (item as { id: string }).id
): T[] {
  if (!order?.length) return [...items];
  const rank = new Map(order.map((id, index) => [id, index]));
  const ordered: T[] = [];
  const arrivals: T[] = [];
  for (const item of items) (rank.has(idOf(item)) ? ordered : arrivals).push(item);
  ordered.sort((left, right) => rank.get(idOf(left))! - rank.get(idOf(right))!);
  return [...arrivals, ...ordered];
}
