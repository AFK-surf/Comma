import { useCommaMessages } from "@comma/i18n/react";
import {
  Cursor1Icon,
  MacbookIcon,
  MediaExpandIcon,
  PanelRightIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { registerKeepClearElement } from "@comma/ui/components/keep-clear/keepClear";
import { usePointerPressFeedback } from "@comma/ui/components/chat-panel/usePointerPressFeedback";
import { Tooltip } from "@comma/ui/components/tooltip";
import { isReducedMotionEnabled, motionDuration } from "@comma/ui/tokens";
import {
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type RefObject,
} from "react";
import { createPortal } from "react-dom";
import {
  ScreenStreamStage,
  useFullscreen,
  type ScreenStreamSource,
  type ScreenStreamTarget,
} from "./ScreenStreamStage";
import {
  frontScreenCard,
  holdScreenDeck,
  placeScreenCard,
  springFrames,
  useScreenDeck,
  type DragRoom,
} from "./screenDeck";
import type { ScreenStreamState } from "./screenStreamPeer";

/**
 * A small floating card that shows a computer's screen live: one app's
 * windows, or the whole desktop. The picture fills it; its name sits on the
 * picture and its actions show on hover. It drags anywhere and only shows:
 * the computer is controlled from the big screen, which is the side panel
 * (`onExpand`) or this card filling the screen.
 *
 * It opens in the top end corner of `containment`, clear of the reading
 * column and the composer, like the video that keeps playing in a corner. That
 * video keeps clear of it.
 */
export function ScreenStreamWindow({
  appName,
  source,
  containment,
  deckKey,
  onExpand,
  onClose,
}: {
  /** The streamed app's name, when the Agent named one. */
  appName: string | undefined;
  source: ScreenStreamSource;
  /** This card's identity in the deck of cards (screenDeck.ts). */
  deckKey: string;
  /** The area the card rests in; the whole window when absent. */
  containment?: HTMLElement | null | undefined;
  /** Opens the screen in the side panel; absent where there is none. */
  onExpand?: (() => void) | undefined;
  onClose(): void;
}) {
  const messages = useCommaMessages();
  const [target, setTarget] = useState<ScreenStreamTarget>("app");
  const [wantsControl, setWantsControl] = useState(false);
  const [state, setState] = useState<ScreenStreamState>("connecting");
  // It shows once its first picture plays: a card that is still connecting,
  // or never connects, is not put in front of the person.
  const [ready, setReady] = useState(false);
  const { depth, count, duplicate } = useScreenDeck(deckKey, ready);
  const behind = depth > 0;
  const [dragging, setDragging] = useState(false);
  // The picture's shape, once it has one: the card takes it.
  const [ratio, setRatio] = useState(16 / 10);
  const card = useRef<HTMLElement>(null);
  const [full, toggleFull] = useFullscreen(card, wantsControl);
  const control = full && wantsControl;
  // The corner it rests in: the containment's top end corner, as the area resizes.
  const [corner, setCorner] = useState({ x: 0, y: 0 });
  useLayoutEffect(() => {
    const element = card.current;
    if (!element) return undefined;
    const rest = () => {
      const area = containment?.getBoundingClientRect() ?? {
        top: 0,
        right: document.documentElement.clientWidth,
      };
      const inset =
        Number.parseFloat(getComputedStyle(element).getPropertyValue("--spacing-xl")) ||
        16;
      setCorner({ x: area.right - inset - element.offsetWidth, y: area.top + inset });
    };
    rest();
    const observer = new ResizeObserver(rest);
    observer.observe(containment ?? document.documentElement);
    observer.observe(element);
    return () => observer.disconnect();
  }, [behind, containment, duplicate]);
  useLayoutEffect(
    () => (card.current && ready ? registerKeepClearElement(card.current) : undefined),
    [behind, duplicate, ready]
  );
  // The deck writes the card's place: its resting corner and where the deck is.
  useLayoutEffect(() => {
    const element = card.current;
    if (!element) return undefined;
    if (!full) return placeScreenCard(deckKey, element, corner);
    // Filling the screen it has no place of its own.
    element.style.translate = "";
    return undefined;
  }, [behind, corner, deckKey, duplicate, full]);

  // Held, the card stays under the pointer where it was taken (screenDeck.ts).
  const drag = (event: ReactPointerEvent<HTMLElement>) => {
    if (
      full ||
      dragging ||
      !event.isPrimary ||
      event.button !== 0 ||
      (event.target as HTMLElement).closest("button")
    )
      return;
    const handle = event.currentTarget;
    const hold = holdScreenDeck(
      deckKey,
      { x: event.clientX, y: event.clientY },
      dragRoom(handle, containment, corner)
    );
    if (!hold) return;
    handle.setPointerCapture(event.pointerId);
    setDragging(true);
    const onMove = (moved: PointerEvent) => {
      if (moved.pointerId === event.pointerId)
        hold.move({ x: moved.clientX, y: moved.clientY });
    };
    const onUp = (ended: PointerEvent) => {
      if (ended.pointerId !== event.pointerId) return;
      handle.removeEventListener("pointermove", onMove);
      handle.removeEventListener("pointerup", onUp);
      handle.removeEventListener("pointercancel", onUp);
      setDragging(false);
      hold.end();
    };
    handle.addEventListener("pointermove", onMove);
    handle.addEventListener("pointerup", onUp);
    handle.addEventListener("pointercancel", onUp);
  };

  // It arrives out of the corner it rests in, on a spring with no overshoot,
  // and leaves the same way back as a still of its last frame: closed by the
  // person, or because the Agent's session ended.
  const cancelExit = useRef<(() => void) | undefined>(undefined);
  useLayoutEffect(() => {
    const element = card.current;
    cancelExit.current?.();
    cancelExit.current = undefined;
    if (!element || behind || !ready) return undefined;
    arrive(element);
    return () => {
      cancelExit.current = leaveAsStill(element);
    };
  }, [behind, duplicate, ready]);

  const title =
    target === "display"
      ? messages.remote_screen_desktop()
      : (appName ?? messages.remote_screen_app());

  if (duplicate) return null;
  // Behind the front card: an edge of it alone, which brings it to the front. It holds no stream.
  if (behind) {
    return createPortal(
      <button
        aria-label={title}
        className="comma-remote-screen"
        data-depth={Math.min(depth, 3)}
        data-testid="remote-screen-behind"
        onClick={() => frontScreenCard(deckKey)}
        ref={card as RefObject<HTMLButtonElement>}
        style={{ "--comma-remote-screen-ratio": ratio } as CSSProperties}
        type="button"
      />,
      document.body
    );
  }

  return createPortal(
    <section
      aria-label={title}
      className="comma-remote-screen"
      data-control={control}
      data-dragging={dragging}
      data-full={full}
      data-pending={!ready}
      data-state={state}
      data-testid={ready ? "remote-screen" : "remote-screen-pending"}
      onPointerDown={drag}
      ref={card}
      style={{ "--comma-remote-screen-ratio": ratio } as CSSProperties}
    >
      <ScreenStreamStage
        control={control}
        onShape={setRatio}
        onState={(next) => {
          setState(next);
          if (next === "live") setReady(true);
        }}
        source={source}
        state={state}
        target={target}
      />
      <div className="comma-remote-screen-name">
        <span aria-hidden className="comma-remote-screen-dot" />
        <strong>{title}</strong>
        {count > 1 ? (
          <span className="comma-remote-screen-count">1/{count}</span>
        ) : null}
      </div>
      <div className="comma-remote-screen-actions">
        <ScreenStreamAction
          icon={<MacbookIcon aria-hidden />}
          label={messages.remote_screen_desktop()}
          onClick={() => setTarget(target === "app" ? "display" : "app")}
          pressed={target === "display"}
        />
        {full ? (
          <ScreenStreamAction
            icon={<Cursor1Icon aria-hidden />}
            label={messages.remote_screen_control()}
            onClick={() => setWantsControl(!wantsControl)}
            pressed={wantsControl}
          />
        ) : onExpand ? (
          <ScreenStreamAction
            icon={<PanelRightIcon aria-hidden />}
            label={messages.remote_screen_expand()}
            onClick={onExpand}
          />
        ) : null}
        <ScreenStreamAction
          icon={<MediaExpandIcon aria-hidden />}
          label={
            full
              ? messages.remote_screen_exit_fullscreen()
              : messages.remote_screen_fullscreen()
          }
          onClick={toggleFull}
          pressed={full}
        />
        {full ? null : (
          <ScreenStreamAction
            icon={<XIcon aria-hidden />}
            label={messages.remote_screen_close()}
            onClick={onClose}
          />
        )}
      </div>
    </section>,
    document.body
  );
}

/** The offsets from its resting corner that keep the card inside its area. */
function dragRoom(
  element: HTMLElement,
  containment: HTMLElement | null | undefined,
  corner: { x: number; y: number }
): DragRoom {
  const inset =
    Number.parseFloat(getComputedStyle(element).getPropertyValue("--spacing-md")) || 8;
  const area = containment?.getBoundingClientRect() ?? {
    left: 0,
    top: 0,
    right: document.documentElement.clientWidth,
    bottom: document.documentElement.clientHeight,
  };
  return {
    minX: area.left + inset - corner.x,
    maxX:
      Math.max(area.left + inset, area.right - inset - element.offsetWidth) - corner.x,
    minY: area.top + inset - corner.y,
    maxY:
      Math.max(area.top + inset, area.bottom - inset - element.offsetHeight) - corner.y,
    width: area.right - area.left,
    height: area.bottom - area.top,
  };
}

// Arriving and leaving are one path, both ways: out of the resting corner and
// back into it. Springs without overshoot: nothing was thrown.
const ARRIVE = springFrames(0.36, 1);
const LEAVE = springFrames(0.26, 1);
// How small it is at the corner end of the path.
const SMALL = 0.86;

const mix = (from: number, to: number, at: number) => from + (to - from) * at;

function arrive(element: HTMLElement) {
  if (typeof element.animate !== "function") return;
  if (isReducedMotionEnabled()) {
    element.animate([{ opacity: 0 }, { opacity: 1 }], {
      duration: motionDuration.stateChange,
    });
    return;
  }
  element.animate(
    ARRIVE.values.map((at) => ({
      scale: String(mix(SMALL, 1, at)),
      // It is there before it has stopped growing.
      opacity: Math.min(1, at * 2.5),
    })),
    { duration: ARRIVE.duration, easing: "linear" }
  );
}

/**
 * Draws the card's exit over the page after it has left the document: a copy
 * with the picture's last frame goes back the way the card came. It starts
 * from how the card looked at that moment, so one that leaves while it still
 * arrives turns round without a jump. Returns a cancel for StrictMode's
 * replayed setup, which runs before the queued exit.
 */
function leaveAsStill(root: HTMLElement) {
  if (typeof root.animate !== "function") return undefined;
  const parent = root.parentNode;
  const frame = root.querySelector("video");
  const look = getComputedStyle(root);
  const from = {
    scale: Number.parseFloat(look.scale) || 1,
    opacity: Number.parseFloat(look.opacity) || 1,
  };
  const still = root.cloneNode(true) as HTMLElement;
  still.setAttribute("aria-hidden", "true");
  still.inert = true;
  still.dataset.leaving = "true";
  delete still.dataset.testid;
  const copy = still.querySelector("video");
  if (copy && frame && frame.videoWidth > 0 && frame.videoHeight > 0) {
    const density = Math.min(
      1,
      (root.clientWidth * devicePixelRatio) / frame.videoWidth,
      (root.clientHeight * devicePixelRatio) / frame.videoHeight
    );
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(frame.videoWidth * density);
    canvas.height = Math.round(frame.videoHeight * density);
    canvas.getContext("2d")?.drawImage(frame, 0, 0, canvas.width, canvas.height);
    copy.replaceWith(canvas);
  }
  let cancelled = false;
  queueMicrotask(() => {
    if (cancelled || !parent) return;
    parent.appendChild(still);
    const exit = isReducedMotionEnabled()
      ? still.animate([{ opacity: from.opacity }, { opacity: 0 }], {
          duration: motionDuration.stateChange,
          fill: "forwards",
        })
      : still.animate(
          LEAVE.values.map((at) => ({
            scale: String(mix(from.scale, SMALL, at)),
            opacity: mix(from.opacity, 0, Math.min(1, at * 1.4)),
          })),
          { duration: LEAVE.duration, easing: "linear", fill: "forwards" }
        );
    void exit.finished.then(() => still.remove()).catch(() => still.remove());
  });
  return () => {
    cancelled = true;
  };
}

/** One round glass button on the picture. `pressed` makes it a toggle. */
export function ScreenStreamAction({
  icon,
  label,
  onClick,
  pressed,
}: {
  icon: ReactNode;
  label: string;
  onClick(): void;
  pressed?: boolean | undefined;
}) {
  // The press answers the pointer alone: a key press gets no motion.
  const press = usePointerPressFeedback<HTMLButtonElement>();
  return (
    <Tooltip content={label} placement="top">
      <button
        aria-label={label}
        aria-pressed={pressed}
        className="comma-remote-screen-action"
        onClick={onClick}
        type="button"
        {...press}
      >
        {icon}
      </button>
    </Tooltip>
  );
}
