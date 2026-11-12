import { cx } from "@comma/ui/components/utils";
import { useCallback, useEffect, useRef, useState, type RefObject } from "react";

/**
 * A list rail beside a route's content (the Inbox's list, Drive's spaces) that the reader may widen: from its default
 * width up to half the window. The width is stored in localStorage like Home's rail folds: per device, since the room
 * a rail takes is a property of the screen in front of the reader. Safe to lose: the rail comes back at its default.
 */

/** A press that moves less than this resets the width instead of resizing. */
const CLICK_SLOP = 3;
/** One arrow key press moves the divider this far. */
const KEY_STEP = 16;

/** The widest a rail may be: half the window, never under its default. */
function maxWidth(minWidth: number) {
  return Math.max(minWidth, Math.floor((globalThis.window?.innerWidth ?? 0) / 2));
}

function clampWidth(width: number, minWidth: number) {
  return Math.min(Math.max(Math.round(width), minWidth), maxWidth(minWidth));
}

function readStoredWidth(key: string, minWidth: number): number | undefined {
  try {
    const raw = globalThis.localStorage?.getItem(key);
    const width = raw ? Number(raw) : Number.NaN;
    return Number.isFinite(width) && width > minWidth ? width : undefined;
  } catch {
    return undefined;
  }
}

function storeWidth(key: string, width: number | undefined) {
  try {
    if (width === undefined) globalThis.localStorage?.removeItem(key);
    else globalThis.localStorage?.setItem(key, String(width));
  } catch {
    // A blocked write still applies for this session.
  }
}

/**
 * A rail's width: the reader's choice (`setWidth`; `undefined` is the default, `minWidth`), held within half the
 * window as the window resizes.
 */
export function useRailWidth(storageKey: string, minWidth: number) {
  const [chosen, setChosen] = useState(() => readStoredWidth(storageKey, minWidth));
  const [, setWindowWidth] = useState(() => globalThis.window?.innerWidth ?? 0);
  useEffect(() => {
    if (chosen === undefined) return;
    const follow = () => setWindowWidth(window.innerWidth);
    window.addEventListener("resize", follow);
    return () => window.removeEventListener("resize", follow);
  }, [chosen]);
  const setWidth = useCallback(
    (width: number | undefined) => {
      const next = width === undefined || width <= minWidth ? undefined : width;
      storeWidth(storageKey, next);
      setChosen(next);
    },
    [minWidth, storageKey]
  );
  return {
    width: chosen === undefined ? minWidth : clampWidth(chosen, minWidth),
    setWidth,
  };
}

function preventSelection(event: Event) {
  event.preventDefault();
}

/** Writes a width the drag reached straight to the rail's box: its own width, or the CSS variable that sizes it. */
function applyWidth(rail: HTMLElement, width: number, variable: string | undefined) {
  if (variable) rail.style.setProperty(variable, `${width}px`);
  else {
    rail.style.flexBasis = `${width}px`;
    rail.style.width = `${width}px`;
  }
}

/**
 * The divider on a rail's right edge. Dragging it resizes the rail between its default width and half the window; a
 * click puts it back to the default. While a drag moves, only the rail's box is written (and its transitions held, by
 * `data-rail-resizing`); the width is kept when the pointer lets go.
 */
export function RailResizeHandle({
  edge = "border",
  hint,
  label,
  minWidth,
  onWidthChange,
  rail,
  testId,
  variable,
  width,
}: {
  /** `border` straddles the rail's border; `inside` stays within a rail that clips its content. */
  edge?: "border" | "inside";
  hint: string;
  label: string;
  minWidth: number;
  onWidthChange: (width: number | undefined) => void;
  rail: RefObject<HTMLElement | null>;
  testId: string;
  /** The CSS variable that sizes the rail, where its width is not its own. */
  variable?: string | undefined;
  width: number;
}) {
  const stop = useRef<(() => void) | null>(null);
  const [resizing, setResizing] = useState(false);
  useEffect(() => () => stop.current?.(), []);

  return (
    <button
      aria-label={label}
      className={cx(
        "comma-rail-resize absolute inset-y-0 z-[3] w-2 cursor-col-resize border-0 bg-transparent p-0",
        edge === "border" ? "-right-1" : "right-0"
      )}
      data-comma-functional-cursor=""
      data-edge={edge}
      data-resizing={resizing ? "true" : undefined}
      data-testid={testId}
      onKeyDown={(event) => {
        if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
          event.preventDefault();
          onWidthChange(
            clampWidth(
              width + (event.key === "ArrowRight" ? KEY_STEP : -KEY_STEP),
              minWidth
            )
          );
        } else if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onWidthChange(undefined);
        }
      }}
      onPointerDown={(event) => {
        const element = rail.current;
        if (event.button !== 0 || !element) return;
        event.preventDefault();
        stop.current?.();
        const target = event.currentTarget;
        const pointerId = event.pointerId;
        const startX = event.clientX;
        const startWidth = width;
        let dragged = false;
        let next = startWidth;
        target.setPointerCapture?.(pointerId);
        document.addEventListener("selectstart", preventSelection);
        const move = (moved: PointerEvent) => {
          if (moved.pointerId !== pointerId) return;
          const dx = moved.clientX - startX;
          if (!dragged && Math.abs(dx) < CLICK_SLOP) return;
          if (!dragged) {
            dragged = true;
            element.dataset.railResizing = "true";
            setResizing(true);
          }
          next = clampWidth(startWidth + dx, minWidth);
          applyWidth(element, next, variable);
        };
        const end = (ended: PointerEvent) => {
          if (ended.pointerId !== pointerId) return;
          finish();
          // A cancelled drag leaves the width it started from.
          if (ended.type !== "pointerup") {
            if (dragged) applyWidth(element, startWidth, variable);
            return;
          }
          // A click without a drag puts the rail back to its default width.
          onWidthChange(dragged ? next : undefined);
        };
        const finish = () => {
          target.removeEventListener("pointermove", move);
          target.removeEventListener("pointerup", end);
          target.removeEventListener("pointercancel", end);
          document.removeEventListener("selectstart", preventSelection);
          if (target.hasPointerCapture?.(pointerId))
            target.releasePointerCapture(pointerId);
          delete element.dataset.railResizing;
          setResizing(false);
          stop.current = null;
        };
        target.addEventListener("pointermove", move);
        target.addEventListener("pointerup", end);
        target.addEventListener("pointercancel", end);
        stop.current = finish;
      }}
      title={hint}
      type="button"
    />
  );
}
