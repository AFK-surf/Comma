import { useCommaMessages } from "@comma/i18n/react";
import { useRef, type MouseEvent, type RefObject } from "react";
import type { BrowserInput } from "../../../../api/browser";
import {
  keyDownInput,
  keyUpInput,
  modifierReleases,
  pointerInput,
  wheelInput,
  type BrowserViewport,
  type PointerInputType,
} from "./browserInput";

/**
 * The remote tab's pixels. The reader's mouse and keyboard reach the tab only
 * while they control it.
 */
export function BrowserScreen({
  canvas,
  controlling,
  send,
  viewport,
}: {
  canvas: RefObject<HTMLCanvasElement | null>;
  controlling: boolean;
  send: (input: BrowserInput) => void;
  viewport: RefObject<BrowserViewport>;
}) {
  const messages = useCommaMessages();
  const lastMove = useRef(0);
  const pointer = (event: MouseEvent<HTMLCanvasElement>, type: PointerInputType) => {
    if (!controlling) return;
    event.preventDefault();
    if (type === "mousePressed") event.currentTarget.focus();
    send(pointerInput(event, type, viewport.current));
  };
  return (
    <canvas
      ref={canvas}
      width={1280}
      height={720}
      tabIndex={0}
      aria-label={messages.chat_browser_screen()}
      className="block aspect-video w-full bg-black outline-none focus-visible:ring-2"
      onContextMenu={(event) => event.preventDefault()}
      onPointerMove={(event) => {
        if (Date.now() - lastMove.current < 100) return;
        lastMove.current = Date.now();
        pointer(event, "mouseMoved");
      }}
      onPointerDown={(event) => {
        if (controlling) event.currentTarget.setPointerCapture(event.pointerId);
        pointer(event, "mousePressed");
      }}
      onPointerUp={(event) => {
        pointer(event, "mouseReleased");
        if (event.currentTarget.hasPointerCapture(event.pointerId))
          event.currentTarget.releasePointerCapture(event.pointerId);
      }}
      onKeyDown={(event) => {
        if (!controlling || event.nativeEvent.isComposing) return;
        event.preventDefault();
        send(keyDownInput(event));
      }}
      onKeyUp={(event) => {
        if (!controlling) return;
        event.preventDefault();
        send(keyUpInput(event));
      }}
      onBlur={() => {
        for (const input of modifierReleases()) send(input);
      }}
      onWheel={(event) => {
        if (!controlling) return;
        send(wheelInput(event, viewport.current));
      }}
    />
  );
}
