import {
  isReducedMotionEnabled,
  motionDuration,
  motionEasing,
  spacing,
} from "@comma/ui";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import {
  boundPointerReorderTranslation,
  cancelFlipAnimations,
  sameStringOrder,
} from "../pointerReorder";

type PointerDrag = {
  active: boolean;
  captureTarget: HTMLElement;
  currentClientY: number;
  draggedId: string;
  initialOrder: readonly string[];
  initialTops: ReadonlyMap<string, number>;
  pointerId: number;
  rowHeight: number;
  /** Distance between adjacent row tops: a displaced row travels this far. */
  slotStep: number;
  sourceIndex: number;
  startClientY: number;
  startRowTop: number;
  targetIndex: number;
};

export type SidebarNavRowProps = {
  onClickCapture: (event: ReactMouseEvent<HTMLElement>) => void;
  onLostPointerCapture: (event: ReactPointerEvent<HTMLElement>) => void;
  onPointerCancel: (event: ReactPointerEvent<HTMLElement>) => void;
  onPointerDown: (event: ReactPointerEvent<HTMLElement>) => void;
  onPointerMove: (event: ReactPointerEvent<HTMLElement>) => void;
  onPointerUp: (event: ReactPointerEvent<HTMLElement>) => void;
};

// The press has to travel this far before it is a drag; a shorter one is the
// click the link already handles.
const activationThreshold = spacing.xs;

function setSidebarDragCursor(active: boolean) {
  if (active) {
    document.documentElement.setAttribute("data-comma-sidebar-dragging", "true");
  } else {
    document.documentElement.removeAttribute("data-comma-sidebar-dragging");
  }
}

/**
 * Pointer reordering for the icon rail, the way the routine cards reorder:
 * the pressed row lifts and rides the pointer, its neighbours glide aside on
 * a CSS transition, and the drop commits the new order while every row FLIPs
 * from where it was painted into its new slot. The whole item is the handle,
 * so a press that never travels stays the link's own click.
 */
export function useSidebarNavReorder({
  onOrderChange,
  order,
  suspended,
}: {
  onOrderChange: (nextOrder: readonly string[]) => void;
  order: readonly string[];
  /** The rail is collapsed: no drag can start and one in flight is dropped. */
  suspended: boolean;
}) {
  const [dragging, setDragging] = useState(false);
  const listRef = useRef<HTMLElement | null>(null);
  const rowRefs = useRef(new Map<string, HTMLElement>());
  const orderRef = useRef(order);
  orderRef.current = order;
  const dragRef = useRef<PointerDrag | null>(null);
  const frameRef = useRef<number | null>(null);
  const previousTops = useRef(new Map<string, number>());
  const pendingLayoutAnimation = useRef(false);
  const suppressClick = useRef(false);
  const clickResetTimer = useRef<number | null>(null);
  const releasePointerRef = useRef<(() => void) | null>(null);

  const registerRow = useCallback((id: string, element: HTMLElement | null) => {
    if (element) rowRefs.current.set(id, element);
    else rowRefs.current.delete(id);
  }, []);

  const measureRowTops = useCallback(() => {
    const tops = new Map<string, number>();
    rowRefs.current.forEach((element, id) => {
      if (element.isConnected) tops.set(id, element.getBoundingClientRect().top);
    });
    return tops;
  }, []);

  const animateRowsFromTops = useCallback(
    (fromTops: ReadonlyMap<string, number>) => {
      const nextTops = measureRowTops();
      previousTops.current = nextTops;
      pendingLayoutAnimation.current = false;
      if (isReducedMotionEnabled()) return;

      for (const id of orderRef.current) {
        const before = fromTops.get(id);
        const after = nextTops.get(id);
        if (before === undefined || after === undefined || before === after) continue;
        const row = rowRefs.current.get(id);
        if (!row) continue;
        cancelFlipAnimations(row);
        row.animate(
          [
            { transform: `translateY(${before - after}px)` },
            { transform: "translateY(0)" },
          ],
          {
            duration: motionDuration.spatialMove,
            easing: motionEasing.surfaceSmoothOut,
          }
        );
      }
    },
    [measureRowTops]
  );

  // The commit re-keys the rows; the observer runs before that reorder paints,
  // so the settle starts from where the rows were last seen.
  useLayoutEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const observer = new MutationObserver(() => {
      if (!pendingLayoutAnimation.current) return;
      animateRowsFromTops(previousTops.current);
    });
    observer.observe(list, { childList: true });
    return () => observer.disconnect();
  }, [animateRowsFromTops]);

  const clearTransforms = useCallback(() => {
    listRef.current?.style.removeProperty("--comma-sidebar-drag-shift");
    rowRefs.current.forEach((row) => {
      row.removeAttribute("data-pointer-dragging");
      row.removeAttribute("data-sidebar-drag-shift");
      row.style.removeProperty("transform");
    });
  }, []);

  const updateDrag = useCallback((clientY: number) => {
    const drag = dragRef.current;
    if (!drag) return;
    drag.currentClientY = clientY;

    let pointerDeltaY = clientY - drag.startClientY;
    if (!drag.active) {
      if (Math.abs(pointerDeltaY) < activationThreshold) return;
      drag.active = true;
      // Consume the activation threshold so the row starts from rest under the
      // pointer instead of jumping by the accumulated slack.
      const consumedThreshold = Math.sign(pointerDeltaY) * activationThreshold;
      drag.startClientY += consumedThreshold;
      pointerDeltaY -= consumedThreshold;
      // Capture only now: Chromium delivers the click to the capturing
      // element, so a press captured at pointerdown would take the click off
      // the link. Once the row is a drag, the click is its to swallow.
      drag.captureTarget.setPointerCapture(drag.pointerId);
      listRef.current?.style.setProperty(
        "--comma-sidebar-drag-shift",
        `${drag.slotStep}px`
      );
      setSidebarDragCursor(true);
      setDragging(true);
    }

    const translatedY = boundPointerReorderTranslation(
      pointerDeltaY,
      drag.initialTops,
      drag.startRowTop
    );
    const draggedCenter = drag.startRowTop + pointerDeltaY + drag.rowHeight / 2;
    let targetIndex = 0;
    for (const id of drag.initialOrder) {
      if (id === drag.draggedId) continue;
      const top = drag.initialTops.get(id);
      if (top !== undefined && draggedCenter > top + drag.rowHeight / 2)
        targetIndex += 1;
    }
    drag.targetIndex = targetIndex;

    rowRefs.current.forEach((row, id) => {
      if (id === drag.draggedId) {
        row.setAttribute("data-pointer-dragging", "true");
        row.style.transform = `translate3d(0, ${translatedY}px, 0)`;
        return;
      }
      const index = drag.initialOrder.indexOf(id);
      const shiftsUp =
        targetIndex > drag.sourceIndex &&
        index > drag.sourceIndex &&
        index <= targetIndex;
      const shiftsDown =
        targetIndex < drag.sourceIndex &&
        index >= targetIndex &&
        index < drag.sourceIndex;
      if (shiftsUp) row.setAttribute("data-sidebar-drag-shift", "up");
      else if (shiftsDown) row.setAttribute("data-sidebar-drag-shift", "down");
      // "none" keeps the shift transition armed: dropping the attribute would
      // fall back to the base rule, which has no transform transition, and the
      // row would snap home instead of gliding when the drag reverses.
      else row.setAttribute("data-sidebar-drag-shift", "none");
    });
  }, []);

  // Pointer moves arrive faster than frames paint; one rAF applies the latest.
  const queueDrag = useCallback(
    (clientY: number) => {
      const drag = dragRef.current;
      if (!drag) return;
      drag.currentClientY = clientY;
      if (frameRef.current !== null) return;
      frameRef.current = requestAnimationFrame(() => {
        frameRef.current = null;
        const current = dragRef.current;
        if (current) updateDrag(current.currentClientY);
      });
    },
    [updateDrag]
  );

  const finishDrag = useCallback(
    (commit: boolean) => {
      const drag = dragRef.current;
      if (!drag) return;
      if (frameRef.current !== null) {
        cancelAnimationFrame(frameRef.current);
        frameRef.current = null;
        updateDrag(drag.currentClientY);
      }
      dragRef.current = null;
      if (drag.captureTarget.hasPointerCapture(drag.pointerId)) {
        drag.captureTarget.releasePointerCapture(drag.pointerId);
      }

      if (!drag.active) {
        clearTransforms();
        return;
      }

      // Cancellation can precede pointerup (Escape, collapse, capture loss).
      // Keep swallowing the gesture's click until the document sees its end.
      suppressClick.current = true;

      const visualTops = measureRowTops();
      rowRefs.current.forEach((row) => cancelFlipAnimations(row));
      const nextOrder = drag.initialOrder.filter((id) => id !== drag.draggedId);
      nextOrder.splice(drag.targetIndex, 0, drag.draggedId);
      clearTransforms();
      setSidebarDragCursor(false);
      setDragging(false);
      const settlingRow = rowRefs.current.get(drag.draggedId);
      if (settlingRow) {
        // Keep the lifted row above the rows it may cross while it settles.
        settlingRow.setAttribute("data-sidebar-drag-settling", "true");
        window.setTimeout(() => {
          settlingRow.removeAttribute("data-sidebar-drag-settling");
        }, motionDuration.spatialMove);
      }

      if (commit && !sameStringOrder(nextOrder, drag.initialOrder)) {
        previousTops.current = visualTops;
        pendingLayoutAnimation.current = true;
        onOrderChange(nextOrder);
      } else {
        animateRowsFromTops(visualTops);
      }
    },
    [animateRowsFromTops, clearTransforms, measureRowTops, onOrderChange, updateDrag]
  );

  const startDrag = useCallback(
    (id: string, event: ReactPointerEvent<HTMLElement>) => {
      if (!event.isPrimary || event.button !== 0 || dragRef.current || suspended)
        return;
      const row = rowRefs.current.get(id);
      if (!row) return;

      // Neither a native link drag nor a text selection may start under the
      // press; focus stays where it is, as it does for the routine handle.
      event.preventDefault();
      releasePointerRef.current?.();
      if (clickResetTimer.current !== null) {
        window.clearTimeout(clickResetTimer.current);
        clickResetTimer.current = null;
      }
      suppressClick.current = false;
      // Observe the whole gesture, including a release outside the rail after
      // cancellation. The click follows pointerup before the next timer task.
      const { pointerId } = event;
      const closePress = (pointerEvent: PointerEvent) => {
        if (pointerEvent.pointerId !== pointerId) return;
        const drag = dragRef.current;
        if (drag && !drag.active) finishDrag(false);
        releasePointerRef.current?.();
        releasePointerRef.current = null;
        clickResetTimer.current = window.setTimeout(() => {
          suppressClick.current = false;
          clickResetTimer.current = null;
        }, 0);
      };
      document.addEventListener("pointerup", closePress, true);
      document.addEventListener("pointercancel", closePress, true);
      releasePointerRef.current = () => {
        document.removeEventListener("pointerup", closePress, true);
        document.removeEventListener("pointercancel", closePress, true);
      };
      rowRefs.current.forEach((navRow) => cancelFlipAnimations(navRow));
      const initialOrder = [...orderRef.current];
      const initialTops = measureRowTops();
      const rowBounds = row.getBoundingClientRect();
      const firstTop = initialTops.get(initialOrder[0] ?? "");
      const secondTop = initialTops.get(initialOrder[1] ?? "");
      const slotStep =
        firstTop !== undefined && secondTop !== undefined
          ? secondTop - firstTop
          : rowBounds.height;
      dragRef.current = {
        active: false,
        captureTarget: event.currentTarget,
        currentClientY: event.clientY,
        draggedId: id,
        initialOrder,
        initialTops,
        pointerId,
        rowHeight: rowBounds.height,
        slotStep,
        sourceIndex: initialOrder.indexOf(id),
        startClientY: event.clientY,
        startRowTop: rowBounds.top,
        targetIndex: initialOrder.indexOf(id),
      };
    },
    [finishDrag, measureRowTops, suspended]
  );

  useEffect(() => {
    const cancelFromKeyboard = (event: KeyboardEvent) => {
      if (event.key === "Escape" && dragRef.current) {
        event.preventDefault();
        event.stopImmediatePropagation();
        finishDrag(false);
      }
    };
    document.addEventListener("keydown", cancelFromKeyboard, true);
    return () => document.removeEventListener("keydown", cancelFromKeyboard, true);
  }, [finishDrag]);

  // A rail that collapses, or an order that changes underneath the pointer,
  // ends the drag where it stands.
  useEffect(() => {
    const drag = dragRef.current;
    if (drag && (suspended || !sameStringOrder(drag.initialOrder, order))) {
      finishDrag(false);
    }
  }, [finishDrag, order, suspended]);

  useEffect(
    () => () => {
      if (frameRef.current !== null) {
        cancelAnimationFrame(frameRef.current);
        frameRef.current = null;
      }
      dragRef.current = null;
      releasePointerRef.current?.();
      releasePointerRef.current = null;
      if (clickResetTimer.current !== null) {
        window.clearTimeout(clickResetTimer.current);
        clickResetTimer.current = null;
      }
      clearTransforms();
      setSidebarDragCursor(false);
    },
    [clearTransforms]
  );

  const rowProps = useCallback(
    (id: string): SidebarNavRowProps => ({
      onClickCapture: (event) => {
        if (!suppressClick.current || event.detail === 0) return;
        event.preventDefault();
        event.stopPropagation();
      },
      onLostPointerCapture: (event) => {
        if (dragRef.current?.pointerId === event.pointerId) finishDrag(false);
      },
      onPointerCancel: (event) => {
        if (dragRef.current?.pointerId === event.pointerId) finishDrag(false);
      },
      onPointerDown: (event) => startDrag(id, event),
      onPointerMove: (event) => {
        if (dragRef.current?.pointerId !== event.pointerId) return;
        event.preventDefault();
        queueDrag(event.clientY);
      },
      onPointerUp: (event) => {
        if (dragRef.current?.pointerId !== event.pointerId) return;
        event.preventDefault();
        dragRef.current.currentClientY = event.clientY;
        finishDrag(true);
      },
    }),
    [finishDrag, queueDrag, startDrag]
  );

  return { dragging, listRef, registerRow, rowProps };
}
