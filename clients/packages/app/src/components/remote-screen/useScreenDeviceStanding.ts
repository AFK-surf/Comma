import { uiClock } from "@comma/ui/clock";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject,
} from "react";
import { flushSync } from "react-dom";
import {
  SCREEN_DEVICE_TURN_MS,
  screenDeviceAgrees,
  screenDeviceShape,
  screenDeviceTurn,
  screenDeviceTurnSettled,
  type ScreenStreamCapabilities,
  type ScreenTurn,
} from "./screenDevice";

const LOOK_EVERY_MS = 40;
// A device can turn with nothing pressed (an app that asks for it), and its turned picture is the first word of it: what
// showed before it is kept this often, on the source's frames alone, so a still screen costs nothing.
const KEEP_EVERY_MS = 300;
const SAME_RATIO = 0.01;

/** How a device stands as the stage draws it. The frame and picture change it together, once. */
export type ScreenDeviceStood = {
  ratio: number | undefined;
  turn: ScreenTurn;
};

type Holding = {
  /** How the device stood, and so the held picture, when this began. */
  from: ScreenTurn;
  since: number;
  lastFrame: number;
  /** When the frame's turn is over. */
  turnEnds: number;
  /** Since when the source has said it stands as the frame does. */
  arrivedAt?: number | undefined;
  stop(): void;
};

/**
 * Keeps the frame and the picture locked together through a turn. A source's picture goes through a lot while its
 * device turns: its old capture rotates, its own rotation plays in the frames, and the new capture arrives at its own
 * time, which on a slow device is seconds. So the last picture is held on the screen, and a press turns the frame at
 * once with that picture on it, one element, which says the press was heard. The device's own picture replaces it in
 * one frame, once it has come and settled and the frame has finished turning. Two orientations never show at once. A
 * press that turned nothing turns back.
 */
export function useScreenDeviceStanding(options: {
  capabilities: ScreenStreamCapabilities | undefined;
  pictureRatio: number | undefined;
  reported: ScreenTurn | undefined;
  animated?: boolean | undefined;
  video: RefObject<HTMLVideoElement | null>;
  still: RefObject<HTMLCanvasElement | null>;
}): { stood: ScreenDeviceStood; holdForTurn(): void } {
  const { capabilities, pictureRatio, reported, video, still } = options;
  const shapes = capabilities?.shapes;
  const turnOf = (ratio: number | undefined, report: ScreenTurn | undefined) =>
    shapes ? screenDeviceTurn(screenDeviceShape(shapes, ratio), ratio, report) : 0;
  const target: ScreenDeviceStood = {
    ratio: pictureRatio,
    turn: turnOf(pictureRatio, reported),
  };
  const [stood, setStood] = useState<ScreenDeviceStood>(target);
  const agreed =
    !shapes ||
    screenDeviceAgrees(screenDeviceShape(shapes, pictureRatio), pictureRatio, reported);
  const latest = useRef({ target, stood, agreed });
  latest.current = { target, stood, agreed };
  const holding = useRef<Holding | null>(null);

  const release = useCallback(() => {
    holding.current?.stop();
    holding.current = null;
    if (still.current) {
      const canvas = still.current;
      delete canvas.dataset.holding;
      // Gone in one frame: no fade of it, as it was, over the picture that replaces it.
      canvas.style.cssText = "transition:none";
      uiClock.after(SCREEN_DEVICE_TURN_MS, () => {
        if (!holding.current) canvas.style.cssText = "";
      });
    }
  }, [still]);

  const kept = useRef<HTMLCanvasElement | null>(null);
  useEffect(() => {
    const picture = video.current;
    if (!shapes || !picture?.requestVideoFrameCallback) return undefined;
    let last = -Infinity;
    let request = 0;
    const onFrame = () => {
      request = picture.requestVideoFrameCallback(onFrame);
      const at = uiClock.monotonic();
      const shown = latest.current.stood.ratio;
      if (
        at - last < KEEP_EVERY_MS ||
        holding.current ||
        shown === undefined ||
        Math.abs(picture.videoWidth / picture.videoHeight - shown) >= SAME_RATIO
      )
        return;
      last = at;
      const canvas = (kept.current ??= document.createElement("canvas"));
      canvas.width = picture.videoWidth;
      canvas.height = picture.videoHeight;
      canvas.getContext("2d")?.drawImage(picture, 0, 0);
    };
    request = picture.requestVideoFrameCallback(onFrame);
    return () => picture.cancelVideoFrameCallback(request);
  }, [shapes, video]);

  /** Holds the last picture on the screen. False where there is none, or nothing moves here. */
  const hold = useCallback((): boolean => {
    if (holding.current) return true;
    if (!shapes || options.animated === false || isReducedMotionEnabled()) return false;
    const picture = video.current;
    const canvas = still.current;
    if (!picture || !canvas || !(picture.videoWidth > 0)) return false;
    // The picture on the frame now; if the video has moved on, what was kept of it. With neither, nothing to hold.
    const { stood: was } = latest.current;
    const current =
      was.ratio !== undefined &&
      Math.abs(picture.videoWidth / picture.videoHeight - was.ratio) < SAME_RATIO;
    const from = current ? picture : kept.current;
    if (!from) return false;
    // A video in a separate screen window belongs to that window's realm.
    canvas.width = current ? picture.videoWidth : from.width;
    canvas.height = current ? picture.videoHeight : from.height;
    canvas.getContext("2d")?.drawImage(from, 0, 0);
    canvas.style.cssText = "";
    canvas.dataset.holding = "true";
    const now = uiClock.monotonic();
    let frameRequest: number | undefined;
    const onFrame = () => {
      if (holding.current) holding.current.lastFrame = uiClock.monotonic();
      frameRequest = picture.requestVideoFrameCallback?.(onFrame);
    };
    frameRequest = picture.requestVideoFrameCallback?.(onFrame);
    let cancelLook = () => {};
    const look = () => {
      const held = holding.current;
      if (!held) return;
      const at = uiClock.monotonic();
      const { target: wanted, stood: shown, agreed: says } = latest.current;
      const arrived = says && wanted.turn === shown.turn && wanted.turn !== held.from;
      if (arrived && held.arrivedAt === undefined) {
        held.arrivedAt = at;
        held.lastFrame = at;
      }
      if (!arrived) held.arrivedAt = undefined;
      const settled = screenDeviceTurnSettled({
        turning: at < held.turnEnds,
        agreed: says,
        arrived,
        // A press predicted a turn the source does not say; or it said another.
        unmoved: wanted.turn === held.from,
        restored: shown.turn === held.from,
        heldMs: at - held.since,
        arrivedMs: held.arrivedAt === undefined ? 0 : at - held.arrivedAt,
        quietMs: at - held.lastFrame,
      });
      if (settled === "swap") {
        // One frame: the source's picture and its frame in place as the held picture goes.
        flushSync(() => setStood(wanted));
        release();
        return;
      }
      if (settled === "release") {
        release();
        return;
      }
      if (settled === "turn") setStood(wanted);
      cancelLook = uiClock.after(LOOK_EVERY_MS, look);
    };
    holding.current = {
      from: was.turn,
      since: now,
      lastFrame: now,
      turnEnds: now,
      stop: () => {
        cancelLook();
        if (frameRequest !== undefined)
          picture.cancelVideoFrameCallback?.(frameRequest);
      },
    };
    cancelLook = uiClock.after(LOOK_EVERY_MS, look);
    return true;
  }, [release, shapes, still, video, options.animated]);

  /** A press: the frame turns now, the way the device will, holding the picture it has. */
  const holdForTurn = useCallback(() => {
    if (!hold()) return;
    const { stood: was } = latest.current;
    setStood({
      ratio: was.ratio === undefined ? undefined : 1 / was.ratio,
      turn: ((was.turn + 90) % 360) as ScreenTurn,
    });
  }, [hold]);

  // What changes without a turn goes at once, frame and picture in one commit. A turn nothing pressed holds what showed.
  useLayoutEffect(() => {
    if (!agreed && stood.ratio !== undefined) hold();
    if (holding.current) return;
    if (target.turn === stood.turn && target.ratio === stood.ratio) return;
    if (target.turn !== stood.turn && stood.ratio !== undefined) hold();
    setStood({ ratio: target.ratio, turn: target.turn });
  }, [agreed, hold, stood, target.ratio, target.turn]);

  // While held, the picture stands as it did, on a frame that may have turned: it turns with the frame, one element.
  const stoodTurn = useRef(stood.turn);
  useLayoutEffect(() => {
    const before = stoodTurn.current;
    stoodTurn.current = stood.turn;
    const held = holding.current;
    const canvas = still.current;
    if (!held || !canvas) return;
    if (before !== stood.turn)
      held.turnEnds = uiClock.monotonic() + SCREEN_DEVICE_TURN_MS;
    const off = (stood.turn - held.from + 360) % 360;
    const screenArea = canvas.parentElement;
    if (off === 0 || !screenArea) {
      canvas.style.cssText = "";
      return;
    }
    const [width, height] = [screenArea.offsetWidth, screenArea.offsetHeight];
    canvas.style.cssText =
      off === 180
        ? `transform:rotate(180deg)`
        : `inset:auto;left:${(width - height) / 2}px;top:${(height - width) / 2}px;width:${height}px;height:${width}px;transform:rotate(${off}deg)`;
  }, [still, stood]);

  return { stood, holdForTurn };
}
