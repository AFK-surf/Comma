// An agent at work on a device: a glowing colourful edge round the device's body, outside it, and over its picture the
// agent's cursor, which glides to where it presses. It is the look an agent has in an in-app browser tab, there drawn inside the page
// (apps/electron/src/main/modules/browser-sidebar/agent/cursor.js, after Computer Use's ColorfulBorder and
// OverlayCursor): the same colours, cursor, sizes and timings. Deviations: the edge glows out from behind the device's
// body or case, where a page's glows in from its viewport's edge; it stays for as long as the lease lasts (the station
// says when it starts and ends), not for the length of one command; the cursor follows a swipe's moves at once; and
// the edge turns in steps, as every endless loop in the app does.
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import {
  useEffect,
  useImperativeHandle,
  useRef,
  type CSSProperties,
  type Ref,
  type RefObject,
} from "react";
import type { ScreenAgentPointer } from "./screenStreamStats";

/** The agent's own colours, whatever the theme (cursor.js `EDGE_COLORS`, and its cursor's blue in a white rim). */
const EDGE_COLORS = [
  "#EFB04C",
  "#E98056",
  "#EA4B6B",
  "#E661A5",
  "#DF8AE9",
  "#C0A0F5",
  "#64B5F5",
  "#7EC9EE",
];
const CURSOR_BLUE = "#1040F2";
const CURSOR_RIM = "#FFFFFF";
/** The cursor's outline on its 101-unit canvas, drawn at `SIZE` with its tip at (17, 13) (cursor.js). */
const CURSOR_PATH = "M23.5 17.4L77.5 37.5L50.5 44.5L43.5 71.5Z";
const SIZE = 28;
const TIP_X = (17 / 101) * SIZE;
const TIP_Y = (13 / 101) * SIZE;
/** How small the cursor dips while the finger is down (cursor.js `moveTo`'s press). */
const PRESS_SCALE = 0.82;
/** The cursor goes once the agent has not pressed for this long; the edge stays while the lease does. */
const IDLE_MS = 3000;
/** A glide's length by how far it goes, in px (cursor.js `moveTo`). */
const glideMs = (distance: number) =>
  Math.round(Math.min(380, Math.max(120, distance * 0.6)));

const EDGE = `conic-gradient(${[...EDGE_COLORS, EDGE_COLORS[0]].join(", ")})`;
const cursorStyle = {
  "--comma-remote-screen-agent-press": PRESS_SCALE,
} as CSSProperties;

/**
 * The glowing edge, behind a device's body (ScreenDeviceFrame draws it there): it shows round the body, outside it.
 * `outline`: the corners of a simulator's case, as a `border-radius`, and `shape` their `corner-shape`; none: the body's
 * own rounded box.
 */
export function ScreenAgentEdge({
  outline,
  shape,
}: {
  outline?: string | undefined;
  shape?: string | undefined;
}) {
  return (
    <span
      aria-hidden
      className="comma-remote-screen-agent-edge"
      data-testid="remote-screen-agent"
      style={{ "--comma-remote-screen-agent-edge": EDGE } as CSSProperties}
    >
      <span
        className="comma-remote-screen-agent-ring"
        style={
          outline
            ? ({
                borderRadius: outline,
                ...(shape ? { cornerShape: shape } : {}),
              } as CSSProperties)
            : undefined
        }
      >
        <span className="comma-remote-screen-agent-turning" />
      </span>
    </span>
  );
}

/**
 * Where a point of the picture (0..1 each way) is within a `<video>` that fits it (`object-fit: contain`), in its
 * parent's pixels; null until the picture has a size.
 */
export function agentPointerPlace(
  video: Pick<
    HTMLVideoElement,
    | "offsetLeft"
    | "offsetTop"
    | "clientWidth"
    | "clientHeight"
    | "videoWidth"
    | "videoHeight"
  >,
  at: { x: number; y: number }
): { left: number; top: number } | null {
  const { offsetLeft, offsetTop, clientWidth, clientHeight, videoWidth, videoHeight } =
    video;
  if (!(videoWidth > 0 && videoHeight > 0 && clientWidth > 0 && clientHeight > 0))
    return null;
  const scale = Math.min(clientWidth / videoWidth, clientHeight / videoHeight);
  const width = videoWidth * scale;
  const height = videoHeight * scale;
  return {
    left: offsetLeft + (clientWidth - width) / 2 + at.x * width,
    top: offsetTop + (clientHeight - height) / 2 + at.y * height,
  };
}

export type ScreenAgentPresenceHandle = {
  /** The agent's finger pressed, moved or lifted there. */
  point(at: ScreenAgentPointer): void;
};

/**
 * The agent's cursor over the picture while its lease on the device lasts (`on`). It takes no press and says nothing
 * to a screen reader: the toolbar says in words that an agent uses the device.
 */
export function ScreenAgentPresence({
  on,
  picture,
  ref,
}: {
  on: boolean;
  /** The picture it lies over: the cursor's place is a share of it. */
  picture: RefObject<HTMLVideoElement | null>;
  ref?: Ref<ScreenAgentPresenceHandle>;
}) {
  const cursor = useRef<HTMLSpanElement>(null);
  const last = useRef<{ left: number; top: number; down: boolean } | null>(null);
  const idle = useRef<CancelUiTimer | undefined>(undefined);
  useImperativeHandle(
    ref,
    () => ({
      point(at) {
        const el = cursor.current;
        const video = picture.current;
        const place = video && agentPointerPlace(video, at);
        if (!el || !place) return;
        const was = last.current;
        // A finger that stays down drags: the cursor is where it is. Else it glides there, unless less motion is asked.
        const still =
          el.ownerDocument.defaultView?.matchMedia("(prefers-reduced-motion: reduce)")
            .matches === true;
        const glides = was !== null && !(was.down && at.down) && !still;
        const ms = glides
          ? glideMs(Math.hypot(place.left - was.left, place.top - was.top))
          : 0;
        el.style.setProperty("--comma-remote-screen-agent-glide", `${ms}ms`);
        el.style.transform = `translate(${place.left - TIP_X}px, ${place.top - TIP_Y}px)`;
        el.dataset.shown = "true";
        el.dataset.down = String(at.down);
        last.current = { ...place, down: at.down };
        idle.current?.();
        idle.current = uiClock.after(IDLE_MS, () => {
          el.dataset.shown = "false";
        });
      },
    }),
    [picture]
  );
  // A lease that ends takes its cursor with it: the next one's starts where it first presses.
  useEffect(() => {
    if (on) return undefined;
    last.current = null;
    idle.current?.();
    idle.current = undefined;
    return undefined;
  }, [on]);
  useEffect(() => () => idle.current?.(), []);
  if (!on) return null;
  return (
    <span aria-hidden className="comma-remote-screen-agent" style={cursorStyle}>
      <span
        className="comma-remote-screen-agent-cursor"
        data-shown="false"
        data-testid="remote-screen-agent-cursor"
        ref={cursor}
      >
        <svg height={SIZE} viewBox="0 0 101 101" width={SIZE}>
          {/* The rim reaches 9 units past the outline, the blue 4 (cursor.js). */}
          {(
            [
              [CURSOR_RIM, 18],
              [CURSOR_BLUE, 8],
            ] as const
          ).map(([color, width]) => (
            <path
              d={CURSOR_PATH}
              fill={color}
              key={color}
              stroke={color}
              strokeLinejoin="round"
              strokeWidth={width}
            />
          ))}
        </svg>
      </span>
    </span>
  );
}
