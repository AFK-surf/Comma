import { uiClock } from "@comma/ui/clock";
import { useCallback, useRef, type PointerEvent as ReactPointerEvent } from "react";
import type { ScreenStreamInput } from "./screenStreamInput";

// A finger's moves reach the device at most this often. Unlike a mouse's (InputFrame), a move between two is dropped:
// the finger's lift carries where it ends.
const MOVE_INTERVAL_MS = 16;
// The wire's pointer buttons: the left one held is the finger.
const FINGER_DOWN = 1;
const FINGER_UP = 0;

type Position = { x: number; y: number };

/**
 * A finger from pointer events: the primary pointer from its press to its
 * release, and a hover is nothing. The wire has one finger and no cancel, so
 * other pointers are left out, and a finger still down when the stream goes
 * lifts where it last was, or the device would feel it there. `point` is
 * undefined while there is no picture to touch.
 */
export function useScreenTouchInput(options: {
  enabled: boolean;
  point(event: ReactPointerEvent): Position | undefined;
  send(input: ScreenStreamInput): void;
}) {
  const finger = useRef<(Position & { id: number; movedAt: number }) | null>(null);
  const calls = useRef(options);
  calls.current = options;

  const onPointerDown = (event: ReactPointerEvent<HTMLElement>) => {
    const at = calls.current.enabled ? calls.current.point(event) : undefined;
    if (!at || event.button !== 0 || !event.isPrimary || finger.current) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    finger.current = { ...at, id: event.pointerId, movedAt: uiClock.monotonic() };
    calls.current.send({ t: "pointer", kind: "down", ...at, buttons: FINGER_DOWN });
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLElement>) => {
    const down = finger.current;
    if (down?.id !== event.pointerId) return;
    const now = uiClock.monotonic();
    if (now - down.movedAt < MOVE_INTERVAL_MS) return;
    const { x, y } = calls.current.point(event) ?? down;
    finger.current = { id: down.id, x, y, movedAt: now };
    calls.current.send({ t: "pointer", kind: "move", x, y, buttons: FINGER_DOWN });
  };
  const lift = (where: "here" | "last") => (event: ReactPointerEvent<HTMLElement>) => {
    const down = finger.current;
    if (down?.id !== event.pointerId) return;
    finger.current = null;
    const { x, y } =
      (where === "here" ? calls.current.point(event) : undefined) ?? down;
    calls.current.send({ t: "pointer", kind: "up", x, y, buttons: FINGER_UP });
  };
  const cancel = useCallback((send: (input: ScreenStreamInput) => void) => {
    const down = finger.current;
    if (!down) return;
    finger.current = null;
    send({ t: "pointer", kind: "up", x: down.x, y: down.y, buttons: FINGER_UP });
  }, []);

  return {
    handlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp: lift("here"),
      onPointerCancel: lift("last"),
      onLostPointerCapture: lift("last"),
    },
    cancel,
  };
}
