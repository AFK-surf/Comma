import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import {
  useCallback,
  useMemo,
  useRef,
  type PointerEvent as ReactPointerEvent,
} from "react";

// Longer than Android's own long press, so a native contextmenu arrives
// first and this one stands down. iOS Safari sends none.
const LONG_PRESS_MS = 550;
const MOVE_TOLERANCE_PX = 10;

/**
 * A touch held still on a message opens the same menu a right-click does: it
 * dispatches `contextmenu` at the finger, which the route's capture handler
 * already reads.
 */
export function useTouchLongPressMenu() {
  const press = useRef<{
    cancel: CancelUiTimer;
    pointerId: number;
    x: number;
    y: number;
  } | null>(null);
  const opened = useRef(false);
  const end = useCallback(() => {
    press.current?.cancel();
    press.current = null;
  }, []);

  const onPointerDown = useCallback(
    (event: ReactPointerEvent<HTMLElement>) => {
      end();
      opened.current = false;
      if (event.pointerType !== "touch" || !event.isPrimary) return;
      const target = event.target;
      if (!(target instanceof Element)) return;
      const { clientX: x, clientY: y, pointerId } = event;
      press.current = {
        cancel: uiClock.after(LONG_PRESS_MS, () => {
          press.current = null;
          opened.current = true;
          target.dispatchEvent(
            new MouseEvent("contextmenu", {
              bubbles: true,
              cancelable: true,
              clientX: x,
              clientY: y,
            })
          );
        }),
        pointerId,
        x,
        y,
      };
    },
    [end]
  );
  const onPointerMove = useCallback(
    (event: ReactPointerEvent<HTMLElement>) => {
      const current = press.current;
      if (!current || current.pointerId !== event.pointerId) return;
      if (
        Math.hypot(event.clientX - current.x, event.clientY - current.y) >
        MOVE_TOLERANCE_PX
      )
        end();
    },
    [end]
  );
  // The press that opened the menu must not also activate what it held.
  const onClickCapture = useCallback(
    (event: { preventDefault(): void; stopPropagation(): void }) => {
      if (!opened.current) return;
      opened.current = false;
      event.preventDefault();
      event.stopPropagation();
    },
    []
  );

  return useMemo(
    () => ({
      onClickCapture,
      // A native long press (Android) already opened the menu.
      onContextMenuCapture: end,
      onPointerCancel: end,
      onPointerDown,
      onPointerMove,
      onPointerUp: end,
    }),
    [end, onClickCapture, onPointerDown, onPointerMove]
  );
}
