import type { KeyboardEvent, MouseEvent, WheelEvent } from "react";
import type { BrowserInput } from "../../../../api/browser";

/** The remote tab's size in its own pixels, from the latest frame. */
export type BrowserViewport = { width: number; height: number };

export type PointerInputType = "mousePressed" | "mouseReleased" | "mouseMoved";

type ModifierKeys = {
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
};

/** The protocol's modifier bits: Alt 1, Control 2, Meta 4, Shift 8. */
function modifiers(event: ModifierKeys) {
  return (
    (event.altKey ? 1 : 0) |
    (event.ctrlKey ? 2 : 0) |
    (event.metaKey ? 4 : 0) |
    (event.shiftKey ? 8 : 0)
  );
}

/** Where the event lands on the remote tab, kept inside its viewport. */
function remotePoint(event: MouseEvent<HTMLCanvasElement>, viewport: BrowserViewport) {
  const box = event.currentTarget.getBoundingClientRect();
  return {
    x: Math.max(
      0,
      Math.min(
        viewport.width,
        ((event.clientX - box.left) * viewport.width) / box.width
      )
    ),
    y: Math.max(
      0,
      Math.min(
        viewport.height,
        ((event.clientY - box.top) * viewport.height) / box.height
      )
    ),
  };
}

export function pointerInput(
  event: MouseEvent<HTMLCanvasElement>,
  type: PointerInputType,
  viewport: BrowserViewport
): BrowserInput {
  return {
    type,
    ...remotePoint(event, viewport),
    button:
      type === "mouseMoved" && !event.buttons
        ? "none"
        : event.buttons & 2 || event.button === 2
          ? "right"
          : event.buttons & 4 || event.button === 1
            ? "middle"
            : "left",
    buttons: event.buttons & 7,
    clickCount: Math.min(3, event.detail || 1),
    modifiers: modifiers(event),
  };
}

export function wheelInput(
  event: WheelEvent<HTMLCanvasElement>,
  viewport: BrowserViewport
): BrowserInput {
  return {
    type: "mouseWheel",
    ...remotePoint(event, viewport),
    button: "none",
    clickCount: 0,
    modifiers: modifiers(event),
    deltaX: Math.max(-4000, Math.min(4000, event.deltaX)),
    deltaY: Math.max(-4000, Math.min(4000, event.deltaY)),
  };
}

/** A printable key without a shortcut modifier types text; any other key is pressed. */
export function keyDownInput(event: KeyboardEvent): BrowserInput {
  return event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey
    ? { type: "text", text: event.key }
    : {
        type: "keyDown",
        key: event.key,
        code: event.code,
        keyCode: event.keyCode,
        modifiers: modifiers(event),
      };
}

export function keyUpInput(event: KeyboardEvent): BrowserInput {
  return {
    type: "keyUp",
    key: event.key,
    code: event.code,
    keyCode: event.keyCode,
    modifiers: modifiers(event),
  };
}

/** Releases every modifier, so none stays held in the tab once focus leaves. */
export function modifierReleases(): BrowserInput[] {
  return ["Shift", "Control", "Alt", "Meta"].map(
    (key): BrowserInput => ({ type: "keyUp", key, code: key, keyCode: 0, modifiers: 0 })
  );
}
