import { useCommaMessages } from "@comma/i18n/react";
import {
  createContext,
  type CSSProperties,
  type ReactNode,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import {
  isReducedMotionEnabled,
  motionDuration,
  motionEasing,
  motionScale,
  spacing,
} from "../../tokens";
import {
  CrossLargeIcon,
  Expand45Icon,
  SquareArrowBottomLeftCornerIcon,
} from "../icons";
import { keepClearRects, subscribeKeepClear } from "../keep-clear/keepClear";
import {
  ChatPanelMediaPlayer,
  MediaControlTooltip,
  mediaControlClassName,
  type MediaPlaybackController,
} from "./ChatPanelMediaPlayer";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

/** A playing video whose own frame is out of the reader's view. */
export interface ChatPanelVideoPictureInPictureSession {
  /** Holds the live `<video>`. The window borrows it and gives it back. */
  video: HTMLElement;
  controller: MediaPlaybackController;
  aspectRatio: number;
  title: string;
  returnLabel: string | undefined;
  onClose: () => void;
  onExpand: () => void;
  onReturn: () => void;
}

interface PictureInPictureStore {
  current: () => {
    owner: string;
    session: ChatPanelVideoPictureInPictureSession;
  } | null;
  hide: (owner: string) => void;
  show: (owner: string, session: ChatPanelVideoPictureInPictureSession) => void;
  subscribe: (listener: () => void) => () => void;
}

const createPictureInPictureStore = (): PictureInPictureStore => {
  let active: ReturnType<PictureInPictureStore["current"]> = null;
  const listeners = new Set<() => void>();
  const notify = () => {
    for (const listener of listeners) listener();
  };
  return {
    current: () => active,
    hide: (owner) => {
      if (active?.owner !== owner) return;
      active = null;
      notify();
    },
    show: (owner, session) => {
      const previous = active;
      active = { owner, session };
      // One window at a time. The video it showed stops and goes home.
      if (previous && previous.owner !== owner) previous.session.onClose();
      notify();
    },
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
};

/**
 * Where a video player sits. The app says when a retained surface is off
 * screen and how to bring it and the player back into view.
 */
export interface ChatPanelVideoSurface {
  /** False while a retained surface stays mounted but off screen. */
  visible?: boolean | undefined;
  /** Puts a retained surface back on screen. */
  reveal?: (() => void) | undefined;
  /** Scrolls a player into view the way its surface scrolls. */
  revealPlayer?: ((player: HTMLElement) => void) | undefined;
  /** Names the way back to the player, for example "Jump to message". */
  returnLabel?: string | undefined;
}

interface ChatPanelVideoSurfaceValue extends ChatPanelVideoSurface {
  pictureInPicture?: PictureInPictureStore | undefined;
}

const ChatPanelVideoSurfaceContext = createContext<ChatPanelVideoSurfaceValue>({});

export const useChatPanelVideoSurface = () => useContext(ChatPanelVideoSurfaceContext);

/** A nested surface is visible only while every surface around it is. */
export function ChatPanelVideoSurfaceProvider({
  children,
  reveal,
  revealPlayer,
  returnLabel,
  visible,
}: ChatPanelVideoSurface & { children: ReactNode }) {
  const parent = useContext(ChatPanelVideoSurfaceContext);
  const value = useMemo(
    () => ({
      ...parent,
      reveal: reveal ?? parent.reveal,
      revealPlayer: revealPlayer ?? parent.revealPlayer,
      returnLabel: returnLabel ?? parent.returnLabel,
      visible: parent.visible !== false && visible !== false,
    }),
    [parent, reveal, revealPlayer, returnLabel, visible]
  );
  return (
    <ChatPanelVideoSurfaceContext.Provider value={value}>
      {children}
    </ChatPanelVideoSurfaceContext.Provider>
  );
}

/**
 * Lets a playing video below it continue in one floating window while its own
 * frame is out of view. The window renders here, outside the surfaces that
 * hold players, so its controls never reach their handlers; its DOM stays in
 * the host's stacking context, under the meeting recorder.
 */
export function ChatPanelVideoPictureInPictureProvider({
  children,
  containment,
}: {
  children: ReactNode;
  /** The area the window stays inside. The whole window when unset. */
  containment?: HTMLElement | null | undefined;
}) {
  const parent = useContext(ChatPanelVideoSurfaceContext);
  const [store] = useState(createPictureInPictureStore);
  const value = useMemo(
    () => ({ ...parent, pictureInPicture: store }),
    [parent, store]
  );
  const active = useSyncExternalStore(store.subscribe, store.current, store.current);
  return (
    <ChatPanelVideoSurfaceContext.Provider value={value}>
      {children}
      {active ? (
        <PictureInPictureWindow
          containment={containment}
          key={active.owner}
          session={active.session}
        />
      ) : null}
    </ChatPanelVideoSurfaceContext.Provider>
  );
}

type Corner = { x: "left" | "right"; y: "top" | "bottom" };
/** Distances from the containment's corner to the window's matching corner. */
type Placement = { corner: Corner; x: number; y: number };

/** Where the reader last put the window. Later windows open there too. */
let readerPlacement: Placement | undefined;

const containmentRect = (containment: HTMLElement | null | undefined) =>
  containment?.getBoundingClientRect() ??
  new DOMRect(
    0,
    0,
    document.documentElement.clientWidth,
    document.documentElement.clientHeight
  );

const clampPosition = (
  area: DOMRectReadOnly,
  x: number,
  y: number,
  width: number,
  height: number
) => ({
  x: Math.max(area.left + spacing.md, Math.min(x, area.right - spacing.md - width)),
  y: Math.max(area.top + spacing.md, Math.min(y, area.bottom - spacing.md - height)),
});

const positionFor = (
  placement: Placement,
  area: DOMRectReadOnly,
  width: number,
  height: number
) =>
  clampPosition(
    area,
    placement.corner.x === "left"
      ? area.left + placement.x
      : area.right - placement.x - width,
    placement.corner.y === "top"
      ? area.top + placement.y
      : area.bottom - placement.y - height,
    width,
    height
  );

/** A dropped window keeps its distance to the nearest corner as the app resizes. */
const placementAt = (
  area: DOMRectReadOnly,
  x: number,
  y: number,
  width: number,
  height: number
): Placement => {
  const corner: Corner = {
    x: x + width / 2 < area.left + area.width / 2 ? "left" : "right",
    y: y + height / 2 < area.top + area.height / 2 ? "top" : "bottom",
  };
  return {
    corner,
    x: corner.x === "left" ? x - area.left : area.right - x - width,
    y: corner.y === "top" ? y - area.top : area.bottom - y - height,
  };
};

/**
 * Moves a window off the areas it keeps clear of (the meeting recorder) by the
 * shortest step that still fits: above, below, or beside the area.
 */
const clearOfKeepClear = (
  area: DOMRectReadOnly,
  position: { x: number; y: number },
  width: number,
  height: number
) => {
  let next = position;
  const gap = spacing.md;
  for (const keep of keepClearRects()) {
    if (
      next.x >= keep.right + gap ||
      next.x + width <= keep.left - gap ||
      next.y >= keep.bottom + gap ||
      next.y + height <= keep.top - gap
    ) {
      continue;
    }
    const from = next;
    const [closest] = [
      { x: from.x, y: keep.top - gap - height },
      { x: from.x, y: keep.bottom + gap },
      { x: keep.left - gap - width, y: from.y },
      { x: keep.right + gap, y: from.y },
    ]
      .filter(
        (candidate) =>
          candidate.x >= area.left + gap &&
          candidate.x + width <= area.right - gap &&
          candidate.y >= area.top + gap &&
          candidate.y + height <= area.bottom - gap
      )
      .toSorted(
        (a, b) =>
          Math.hypot(a.x - from.x, a.y - from.y) -
          Math.hypot(b.x - from.x, b.y - from.y)
      );
    if (closest) next = closest;
  }
  return next;
};

/** A first window docks in the top-right corner, clear of the reading column. */
const dockedPlacement: Placement = {
  corner: { x: "right", y: "top" },
  x: spacing.xl,
  y: spacing.xl,
};

/**
 * The window leaves as a still of its last frame, because the live video is
 * already back in its own frame. Returns a cancel for StrictMode's replayed
 * setup, which runs before the queued exit.
 */
const leaveAsStill = (root: HTMLElement, frame: HTMLVideoElement | null) => {
  if (typeof root.animate !== "function") return undefined;
  const parent = root.parentNode;
  const { clientHeight, clientWidth } = root;
  const still = root.cloneNode(true) as HTMLElement;
  still.setAttribute("aria-hidden", "true");
  still.inert = true;
  still.dataset.leaving = "true";
  if (root.matches(":hover, :focus-within")) still.dataset.controlsShown = "true";
  const slot = still.querySelector('[data-slot="chat-panel-video-pip-frame"]');
  if (slot && frame && frame.videoWidth > 0 && frame.videoHeight > 0) {
    const density = Math.min(
      1,
      (clientWidth * devicePixelRatio) / frame.videoWidth,
      (clientHeight * devicePixelRatio) / frame.videoHeight
    );
    const canvas = document.createElement("canvas");
    canvas.className = "chat-panel-video-content";
    canvas.width = Math.round(frame.videoWidth * density);
    canvas.height = Math.round(frame.videoHeight * density);
    canvas.getContext("2d")?.drawImage(frame, 0, 0, canvas.width, canvas.height);
    slot.replaceChildren(canvas);
  }
  let cancelled = false;
  queueMicrotask(() => {
    if (cancelled || !parent) return;
    parent.appendChild(still);
    const exit = still.animate(
      isReducedMotionEnabled()
        ? [{ opacity: 1 }, { opacity: 0 }]
        : [
            { opacity: 1, scale: "1" },
            { opacity: 0, scale: String(motionScale.pictureInPicture) },
          ],
      {
        duration: motionDuration.pictureInPictureExit,
        easing: motionEasing.smoothOut,
        fill: "forwards",
      }
    );
    void exit.finished.then(() => still.remove()).catch(() => still.remove());
  });
  return () => {
    cancelled = true;
  };
};

const pictureInPictureControlSelector =
  "button, input, a, dialog, [role='menu'], [role='slider']";

function PictureInPictureWindow({
  containment,
  session,
}: {
  containment: HTMLElement | null | undefined;
  session: ChatPanelVideoPictureInPictureSession;
}) {
  const messages = useCommaMessages();
  const buttonPressFeedback = usePointerPressFeedback<HTMLButtonElement>();
  const rootRef = useRef<HTMLElement | null>(null);
  const frameSlotRef = useRef<HTMLDivElement | null>(null);
  const frameRef = useRef<HTMLVideoElement | null>(null);
  const cancelExitRef = useRef<(() => void) | undefined>(undefined);
  const placementRef = useRef<Placement | undefined>(undefined);
  const positionRef = useRef({ x: 0, y: 0 });
  const dragRef = useRef<
    | {
        height: number;
        left: number;
        pointerId: number;
        top: number;
        width: number;
        x: number;
        y: number;
      }
    | undefined
  >(undefined);
  const { video } = session;

  // The owner can drop its `<video>` (full window) before this window closes;
  // the exit still draws from the element it last showed.
  useLayoutEffect(() => {
    frameRef.current = video.querySelector("video") ?? frameRef.current;
  });

  useLayoutEffect(() => {
    const root = rootRef.current!;
    const home = video.parentElement;
    cancelExitRef.current?.();
    cancelExitRef.current = undefined;
    frameSlotRef.current!.append(video);
    return () => {
      home?.append(video);
      cancelExitRef.current = leaveAsStill(root, frameRef.current);
    };
  }, [video]);

  /**
   * Puts the window where the reader left it, stepped off the recorder. When
   * something else forces the move (the recorder arrives, settles, or leaves;
   * a drop lands on it), the window slides there instead of jumping.
   */
  const place = useCallback(
    (slide = false) => {
      const root = rootRef.current;
      if (!root || dragRef.current) return;
      const placement = (placementRef.current ??= readerPlacement ?? dockedPlacement);
      const area = containmentRect(containment);
      const width = root.offsetWidth;
      const height = root.offsetHeight;
      const position = clearOfKeepClear(
        area,
        positionFor(placement, area, width, height),
        width,
        height
      );
      const moved =
        position.x !== positionRef.current.x || position.y !== positionRef.current.y;
      positionRef.current = position;
      if (slide && moved) root.dataset.settling = "true";
      root.style.translate = `${position.x}px ${position.y}px`;
      root.style.transformOrigin = `${placement.corner.y} ${placement.corner.x}`;
    },
    [containment]
  );

  useLayoutEffect(() => {
    const root = rootRef.current!;
    const follow = () => place();
    const settle = () => place(true);
    const settled = (event: TransitionEvent) => {
      if (event.target === root && event.propertyName === "translate") {
        delete root.dataset.settling;
      }
    };
    place();
    window.addEventListener("resize", follow);
    root.addEventListener("transitionend", settled);
    root.addEventListener("transitioncancel", settled);
    const unsubscribe = subscribeKeepClear(settle);
    const observer = new ResizeObserver(follow);
    observer.observe(root);
    if (containment) observer.observe(containment);
    return () => {
      window.removeEventListener("resize", follow);
      root.removeEventListener("transitionend", settled);
      root.removeEventListener("transitioncancel", settled);
      unsubscribe();
      observer.disconnect();
    };
  }, [containment, place]);

  // Native listeners: most of the window is the owner's `<video>`, whose React
  // events travel through the owner's tree, never this window's.
  useLayoutEffect(() => {
    const root = rootRef.current!;
    const beginDrag = (event: PointerEvent) => {
      if (!event.isPrimary || event.button !== 0 || dragRef.current) return;
      if (
        event.target instanceof Element &&
        event.target.closest(pictureInPictureControlSelector)
      ) {
        return;
      }
      event.preventDefault();
      root.setPointerCapture(event.pointerId);
      delete root.dataset.settling;
      root.dataset.dragging = "true";
      dragRef.current = {
        height: root.offsetHeight,
        left: positionRef.current.x,
        pointerId: event.pointerId,
        top: positionRef.current.y,
        width: root.offsetWidth,
        x: event.clientX,
        y: event.clientY,
      };
    };
    const drag = (event: PointerEvent) => {
      const current = dragRef.current;
      if (current?.pointerId !== event.pointerId) return;
      const position = clampPosition(
        containmentRect(containment),
        current.left + event.clientX - current.x,
        current.top + event.clientY - current.y,
        current.width,
        current.height
      );
      positionRef.current = position;
      root.style.translate = `${position.x}px ${position.y}px`;
    };
    const endDrag = (event: PointerEvent) => {
      const current = dragRef.current;
      if (current?.pointerId !== event.pointerId) return;
      dragRef.current = undefined;
      delete root.dataset.dragging;
      const placement = placementAt(
        containmentRect(containment),
        positionRef.current.x,
        positionRef.current.y,
        current.width,
        current.height
      );
      placementRef.current = placement;
      readerPlacement = placement;
      // Dropped on the recorder: slide off it, keeping the corner the reader chose.
      place(true);
    };
    root.addEventListener("pointerdown", beginDrag);
    root.addEventListener("pointermove", drag);
    root.addEventListener("pointerup", endDrag);
    root.addEventListener("pointercancel", endDrag);
    root.addEventListener("lostpointercapture", endDrag);
    return () => {
      root.removeEventListener("pointerdown", beginDrag);
      root.removeEventListener("pointermove", drag);
      root.removeEventListener("pointerup", endDrag);
      root.removeEventListener("pointercancel", endDrag);
      root.removeEventListener("lostpointercapture", endDrag);
    };
  }, [containment, place]);

  const fullWindowLabel = messages.ui_video_picture_in_picture_full_window();
  const returnLabel =
    session.returnLabel ?? messages.ui_video_picture_in_picture_return();
  const closeLabel = messages.ui_video_picture_in_picture_close();

  return (
    <section
      aria-label={messages.ui_video_picture_in_picture({ title: session.title })}
      className="chat-panel-video-pip"
      data-testid="chat-panel-video-pip"
      ref={rootRef}
      style={
        { "--chat-panel-video-aspect-ratio": session.aspectRatio } as CSSProperties
      }
    >
      <div
        className="chat-panel-video-pip-frame"
        data-slot="chat-panel-video-pip-frame"
        ref={frameSlotRef}
      />
      <div className="chat-panel-video-pip-actions">
        <MediaControlTooltip content={fullWindowLabel} placement="bottom">
          <button
            aria-label={fullWindowLabel}
            className={mediaControlClassName}
            {...buttonPressFeedback}
            onClick={session.onExpand}
            type="button"
          >
            <Expand45Icon className="size-2xl" />
          </button>
        </MediaControlTooltip>
        <MediaControlTooltip content={returnLabel} placement="bottom">
          <button
            aria-label={returnLabel}
            className={mediaControlClassName}
            {...buttonPressFeedback}
            onClick={session.onReturn}
            type="button"
          >
            <SquareArrowBottomLeftCornerIcon className="size-2xl" />
          </button>
        </MediaControlTooltip>
        <MediaControlTooltip content={closeLabel} placement="bottom">
          <button
            aria-label={closeLabel}
            className={mediaControlClassName}
            {...buttonPressFeedback}
            onClick={session.onClose}
            type="button"
          >
            <CrossLargeIcon className="size-2xl" />
          </button>
        </MediaControlTooltip>
      </div>
      <ChatPanelMediaPlayer controller={session.controller} kind="video" tone="dark" />
    </section>
  );
}
