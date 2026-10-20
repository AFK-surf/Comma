import { uiClock } from "@comma/ui/clock";
import { useCommaMessages } from "@comma/i18n/react";
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type RefObject,
} from "react";
import { modifiers, pictureFraction, wireButton } from "./screenStreamInput";
import {
  openScreenStream,
  type ScreenStreamPeer,
  type ScreenStreamState,
} from "./screenStreamPeer";

export type ScreenStreamTarget = "app" | "display";

export type ScreenStreamRequest = {
  target: ScreenStreamTarget;
  control: boolean;
  sdp: string;
  iceServers: RTCIceServer[];
  /** The stage's ground as `#rrggbb`: the computer paints it where the picture has no window. */
  background: string | undefined;
};

/** How a stage reaches the computer whose screen it shows. */
export type ScreenStreamSource = {
  /** The ICE servers for both peers of a stream. */
  iceServers(): Promise<RTCIceServer[]>;
  start(request: ScreenStreamRequest): Promise<{ sdp: string; stream: string }>;
  stop(stream: string): void;
};

// Pointer moves reach the computer at most this often.
const MOVE_INTERVAL_MS = 16;

/**
 * A computer's screen, live: one app's windows or the whole desktop. With
 * `control`, the pointer and keyboard over the picture reach the computer.
 * The stream opens anew when the target or control changes.
 */
export function ScreenStreamStage({
  target,
  control,
  source,
  state,
  onState,
  onShape,
}: {
  target: ScreenStreamTarget;
  control: boolean;
  source: ScreenStreamSource;
  state: ScreenStreamState;
  onState(state: ScreenStreamState): void;
  /** The picture's width over its height, once it has one and whenever it changes. */
  onShape?: ((ratio: number) => void) | undefined;
}) {
  const messages = useCommaMessages();
  const video = useRef<HTMLVideoElement>(null);
  // The last frame of the stream before this one, shown until this one plays.
  const still = useRef<HTMLCanvasElement>(null);
  const peer = useRef<ScreenStreamPeer | null>(null);
  const calls = useRef({ source, onState, onShape });
  calls.current = { source, onState, onShape };

  useEffect(() => {
    calls.current.onState("connecting");
    const picture = video.current;
    const kept = still.current;
    let stream: string | undefined;
    let closed = false;
    const opened = openScreenStream({
      iceServers: () => calls.current.source.iceServers(),
      signal: (sdp, servers) =>
        calls.current.source.start({
          target,
          control,
          sdp,
          iceServers: servers,
          background: video.current?.parentElement
            ? hexColor(getComputedStyle(video.current.parentElement).backgroundColor)
            : undefined,
        }),
      onStream: (media) => {
        if (video.current) video.current.srcObject = media;
      },
      onState: (next) => calls.current.onState(next),
      onStarted: (id) => {
        if (closed) calls.current.source.stop(id);
        else stream = id;
      },
    });
    peer.current = opened;
    return () => {
      closed = true;
      peer.current = null;
      keepLastFrame(picture, kept);
      opened.close();
      if (stream) calls.current.source.stop(stream);
    };
  }, [target, control]);

  // The picture's size arrives with its first frame and changes as the app's windows do.
  useEffect(() => {
    const element = video.current;
    if (!element) return undefined;
    const shape = () => {
      if (element.videoWidth > 0 && element.videoHeight > 0)
        calls.current.onShape?.(element.videoWidth / element.videoHeight);
    };
    element.addEventListener("resize", shape);
    return () => element.removeEventListener("resize", shape);
  }, []);

  const lastMove = useRef(0);
  const point = (event: ReactPointerEvent | WheelEvent) => {
    const element = video.current!;
    return pictureFraction(event, element.getBoundingClientRect(), {
      width: element.videoWidth,
      height: element.videoHeight,
    });
  };
  const press =
    (type: "down" | "up") => (event: ReactPointerEvent<HTMLVideoElement>) => {
      if (!control) return;
      if (type === "down") {
        event.currentTarget.focus();
        event.currentTarget.setPointerCapture(event.pointerId);
      }
      peer.current?.send({
        type,
        ...point(event),
        button: wireButton(event.button),
        clicks: Math.max(1, event.detail),
        mods: modifiers(event),
      });
    };
  const move = (event: ReactPointerEvent<HTMLVideoElement>) => {
    if (!control) return;
    const now = uiClock.monotonic();
    if (now - lastMove.current < MOVE_INTERVAL_MS) return;
    lastMove.current = now;
    peer.current?.send({ type: "move", ...point(event), mods: modifiers(event) });
  };
  const key = (type: "keydown" | "keyup") => (event: ReactKeyboardEvent) => {
    if (!control) return;
    event.preventDefault();
    peer.current?.send({ type, code: event.code, mods: modifiers(event) });
  };

  // React registers wheel listeners as passive; scrolling the picture must not scroll the page.
  useEffect(() => {
    const element = video.current;
    if (!element || !control) return undefined;
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      peer.current?.send({
        type: "scroll",
        ...point(event),
        dx: event.deltaX,
        dy: event.deltaY,
        mods: modifiers(event),
      });
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, [control]);

  return (
    <div className="comma-remote-screen-stage" data-control={control}>
      <video
        autoPlay
        muted
        playsInline
        onContextMenu={(event) => control && event.preventDefault()}
        onKeyDown={key("keydown")}
        onKeyUp={key("keyup")}
        onPointerDown={press("down")}
        onPointerMove={move}
        onPointerUp={press("up")}
        ref={video}
        tabIndex={control ? 0 : -1}
      />
      <canvas aria-hidden className="comma-remote-screen-still" ref={still} />
      {state === "live" ? null : (
        <output className="comma-remote-screen-status">
          {state === "failed"
            ? messages.remote_screen_failed()
            : messages.remote_screen_connecting()}
        </output>
      )}
    </div>
  );
}

/** Draws the video's current frame on the canvas, if it has one. */
function keepLastFrame(
  video: HTMLVideoElement | null,
  canvas: HTMLCanvasElement | null
) {
  if (!video || !canvas || !(video.videoWidth > 0 && video.videoHeight > 0)) return;
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  canvas.getContext("2d")?.drawImage(video, 0, 0);
  canvas.dataset.kept = "true";
}

/** A CSS colour in any notation as `#rrggbb`, by painting it. */
function hexColor(color: string): string | undefined {
  const context = document.createElement("canvas").getContext("2d");
  if (!context) return undefined;
  context.fillStyle = color;
  context.fillRect(0, 0, 1, 1);
  const [red = 0, green = 0, blue = 0] = context.getImageData(0, 0, 1, 1).data;
  return `#${[red, green, blue].map((part) => part.toString(16).padStart(2, "0")).join("")}`;
}

/**
 * Whether the element fills the screen, and a way in and out. While it does and
 * `lockKeys` holds, Escape reaches the page (a long press still leaves), so
 * the computer being controlled gets it.
 */
export function useFullscreen(
  element: RefObject<HTMLElement | null>,
  lockKeys: boolean
): [full: boolean, toggle: () => void] {
  const [full, setFull] = useState(false);
  useEffect(() => {
    const changed = () =>
      setFull(
        element.current !== null && document.fullscreenElement === element.current
      );
    document.addEventListener("fullscreenchange", changed);
    return () => document.removeEventListener("fullscreenchange", changed);
  }, [element]);
  useEffect(() => {
    const keyboard = (
      navigator as {
        keyboard?: { lock?(keys: string[]): Promise<void>; unlock?(): void };
      }
    ).keyboard;
    if (!full || !lockKeys || !keyboard?.lock) return undefined;
    void keyboard.lock(["Escape"]).catch(() => undefined);
    return () => keyboard.unlock?.();
  }, [full, lockKeys]);
  const toggle = useCallback(() => {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void element.current?.requestFullscreen().catch(() => undefined);
  }, [element]);
  return [full, toggle];
}
