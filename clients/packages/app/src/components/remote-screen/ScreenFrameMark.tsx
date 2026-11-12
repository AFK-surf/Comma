import { useCommaMessages } from "@comma/i18n/react";
import { CrossLargeIcon } from "@comma/ui/components/icons";
import { Tooltip } from "@comma/ui/components/tooltip";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent,
  type ReactNode,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import { Composer } from "../chat/composer/Composer";
import { fixedDraftSource } from "../chat/composer/conversationDraft";
import { markPath, type ScreenMark } from "./screenMarks";
import { screenFramePng } from "./screenToChat";

/** A box's line on the screen, in CSS pixels, whatever size the frame shows at: the inspector's on a page. */
const MARK_LINE = 2;
/** The light edge outside a box's line, in CSS pixels: the inspector's, which keeps its box clear on any page. */
const MARK_EDGE = 1;
/**
 * A drag shorter than this on both sides is a press, which selects the whole screen; one shorter on one side alone
 * is taken for a slip of the pointer.
 */
const SHORTEST_DRAG = 6;
/** The edge of a selection's small picture, in pixels: the chat's composer shows it at 64 CSS pixels. */
const TILE_EDGE = 192;
/**
 * The composer for what is selected, as the browser's for a picked element (the browser sidebar's
 * `#showInspectionComposer`): this wide at most, and this far from what it is about and from the dialog's edges.
 */
const COMPOSER_WIDTH = 440;
const COMPOSER_GAP = 12;

/** A place in the held frame's dialog, in CSS pixels from its corner. */
type Box = { left: number; top: number; width: number; height: number };

/** What the person selected on the frame: an area they dragged a box round, or the whole screen (no `area`). */
type Picked = { area: ScreenMark | undefined };

/** A rounded corner, as shares of its box's width and height (none where the corner is square). */
type Corner = { x: number; y: number };
/** A box's corners: top left, then clockwise. */
type Corners = readonly [Corner, Corner, Corner, Corner];
const SQUARE: Corners = [
  { x: 0, y: 0 },
  { x: 0, y: 0 },
  { x: 0, y: 0 },
  { x: 0, y: 0 },
];

/** A length of a computed radius ("12px", "14%") as a share of the side it lies along. */
function shareOf(part: string, side: number): number {
  const size = Number.parseFloat(part) || 0;
  return part.endsWith("%") ? size / 100 : side > 0 ? size / side : 0;
}

/** A corner from its computed `border-*-radius` ("12px", "14% 6%") on a box of this size. */
function cornerOf(computed: string, box: { width: number; height: number }): Corner {
  const [along = "0", across = along] = computed.trim().split(/\s+/u);
  return { x: shareOf(along, box.width), y: shareOf(across, box.height) };
}

/**
 * The outline of the frame's whole screen as path data, `inset` from its edge: each corner as round as the screen
 * shows it there, and no less round than `least` (a box's own corner).
 */
function screenPath(
  width: number,
  height: number,
  corners: Corners,
  inset = 0,
  least = 0
): string {
  const [tl, tr, br, bl] = corners.map((corner) => ({
    x: Math.max(corner.x * width - inset, least),
    y: Math.max(corner.y * height - inset, least),
  })) as [Corner, Corner, Corner, Corner];
  const [left, top, right, bottom] = [inset, inset, width - inset, height - inset];
  return (
    `M${left + tl.x} ${top}H${right - tr.x}A${tr.x} ${tr.y} 0 0 1 ${right} ${top + tr.y}` +
    `V${bottom - br.y}A${br.x} ${br.y} 0 0 1 ${right - br.x} ${bottom}` +
    `H${left + bl.x}A${bl.x} ${bl.y} 0 0 1 ${left} ${bottom - bl.y}` +
    `V${top + tl.y}A${tl.x} ${tl.y} 0 0 1 ${left + tl.x} ${top}Z`
  );
}

/** A selection of the frame to ask about: its picture (a PNG being encoded), a small one for a tile, and the words. */
export type ScreenSelection = {
  picture: Promise<Blob | undefined>;
  thumbnail: string | undefined;
  note: string;
};

/** The largest box of the frame's shape in `room`, in its middle: as `object-fit: contain` lays a picture. */
function contained(room: Box, width: number, height: number): Box {
  const scale = Math.max(0, Math.min(room.width / width, room.height / height));
  return {
    left: room.left + (room.width - width * scale) / 2,
    top: room.top + (room.height - height * scale) / 2,
    width: width * scale,
    height: height * scale,
  };
}

/**
 * The frame's part under `area` (the whole frame without one) on a canvas of its own. With `tile`, the canvas is a
 * square of that edge with the whole part in its middle, clear round it: a composer's tile fills its square with its
 * picture, and would show only the middle of a wide or tall part. Undefined where there is no 2D canvas.
 */
function framePart(
  frame: HTMLCanvasElement,
  area?: ScreenMark,
  tile?: number
): HTMLCanvasElement | undefined {
  const left = Math.max(0, Math.floor(area?.x ?? 0));
  const top = Math.max(0, Math.floor(area?.y ?? 0));
  const width = Math.max(
    1,
    Math.min(frame.width, Math.ceil(area ? area.x + area.width : frame.width)) - left
  );
  const height = Math.max(
    1,
    Math.min(frame.height, Math.ceil(area ? area.y + area.height : frame.height)) - top
  );
  const canvas = frame.ownerDocument.createElement("canvas");
  canvas.width = tile ?? width;
  canvas.height = tile ?? height;
  const context = canvas.getContext("2d");
  if (!context) return undefined;
  const scale = tile ? tile / Math.max(width, height) : 1;
  const shownWidth = Math.max(1, Math.round(width * scale));
  const shownHeight = Math.max(1, Math.round(height * scale));
  context.drawImage(
    frame,
    left,
    top,
    width,
    height,
    Math.round((canvas.width - shownWidth) / 2),
    Math.round((canvas.height - shownHeight) / 2),
    shownWidth,
    shownHeight
  );
  return canvas;
}

/** A round button of the composer's row, as the one that closes the browser's composer for picked elements. */
function MarkComposerAction({
  label,
  onPress,
  children,
}: {
  label: string;
  onPress(): void;
  children: ReactNode;
}) {
  return (
    <Tooltip content={label} placement="top">
      <AriaButton
        aria-label={label}
        className="comma-remote-screen-mark-action"
        onPress={onPress}
      >
        {children}
      </AriaButton>
    </Tooltip>
  );
}

/**
 * A screen being inspected, under the panel's toolbar (`top` from the panel's own top; the same for a Mac's display, a
 * simulator or a phone in its case): what is selected on the frame held as Ask Comma was pressed. The stage shows the
 * frame where its stream played (ScreenStreamStage's `heldFrame`), in the screen's shape and under a device's case, so the
 * device stands as it did and nothing moves. This lies over the stage and takes its presses: the person selects on the
 * frame as they pick an element on a page, a drag for an area and a press for the whole screen. A composer with
 * nothing but its field then shows by the selection, as the browser's does by a picked element. What they write there
 * goes with the selection to the chat's composer (`onAsk`), where it waits as an attachment; the frame stays held for
 * the next selection. The composer's close button or Escape lets the selection go (the selection has no control of its
 * own); Escape with nothing selected puts the frame away.
 *
 * The panel makes the stage and the bars under it inert while it shows, so what is pressed or typed never reaches the
 * remote screen. Where no stage shows the frame, it shows it itself.
 */
export function ScreenFrameMark({
  frame,
  top,
  onAsk,
  onCancel,
}: {
  frame: HTMLCanvasElement;
  top: number;
  /** The whole screen at its decoded size, or the area cut from it, with what the person wrote about it. */
  onAsk(selection: ScreenSelection): void;
  onCancel(): void;
}) {
  const messages = useCommaMessages();
  const [picked, setPicked] = useState<Picked | undefined>();
  const [drawing, setDrawing] = useState<ScreenMark | undefined>();
  const [draft, setDraft] = useState("");
  const draftSource = useMemo(() => fixedDraftSource(draft), [draft]);
  const dialog = useRef<HTMLDialogElement>(null);
  const shown = useRef<HTMLDivElement>(null);
  const composer = useRef<HTMLDivElement>(null);
  const surface = useRef<SVGSVGElement>(null);
  const from = useRef<{ x: number; y: number; pointer: number } | undefined>(undefined);
  const [placed, setPlaced] = useState<Box | undefined>();
  const [corners, setCorners] = useState<Corners>(SQUARE);
  const [room, setRoom] = useState<{ width: number; height: number } | undefined>();
  const [composerHeight, setComposerHeight] = useState<number | undefined>();
  const clip = useId();
  const area = picked?.area;
  // The whole screen selected: the areas' line round the frame, inside its edge.
  const wholeLine = placed ? (MARK_LINE * frame.width) / placed.width : undefined;
  const wholeMark: ScreenMark | undefined =
    picked && !area && wholeLine
      ? {
          x: wholeLine / 2,
          y: wholeLine / 2,
          width: frame.width - wholeLine,
          height: frame.height - wholeLine,
          line: wholeLine,
        }
      : undefined;

  // Where the frame shows, and in what shape: the stage has it in its picture's place by now (its effect runs before
  // this one), and what holds it there has the screen's corners. The selection is laid on that.
  useLayoutEffect(() => {
    const element = dialog.current;
    if (!element) return undefined;
    if (!frame.isConnected) shown.current?.replaceChildren(frame);
    const place = () => {
      const all = element.getBoundingClientRect();
      const showing = frame.getBoundingClientRect();
      const to = contained(
        {
          left: showing.left - all.left,
          top: showing.top - all.top,
          width: showing.width,
          height: showing.height,
        },
        frame.width,
        frame.height
      );
      setPlaced((now) =>
        now &&
        now.left === to.left &&
        now.top === to.top &&
        now.width === to.width &&
        now.height === to.height
          ? now
          : to
      );
      const holder = frame.parentElement;
      const look = holder ? getComputedStyle(holder) : undefined;
      const round: Corners = look
        ? [
            cornerOf(look.borderTopLeftRadius, showing),
            cornerOf(look.borderTopRightRadius, showing),
            cornerOf(look.borderBottomRightRadius, showing),
            cornerOf(look.borderBottomLeftRadius, showing),
          ]
        : SQUARE;
      setCorners((now) =>
        now.every(
          (corner, at) => corner.x === round[at]!.x && corner.y === round[at]!.y
        )
          ? now
          : round
      );
      setRoom((now) =>
        now && now.width === all.width && now.height === all.height
          ? now
          : { width: all.width, height: all.height }
      );
    };
    place();
    const observer = new ResizeObserver(place);
    observer.observe(element);
    observer.observe(frame);
    return () => observer.disconnect();
  }, [frame]);

  // The composer shows once something is selected: its height, to lay it by the selection.
  const composing = picked !== undefined;
  useLayoutEffect(() => {
    const element = composer.current;
    if (!composing || !element) return setComposerHeight(undefined);
    const measure = () => setComposerHeight(element.offsetHeight);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [composing]);
  // Under the selection, or over it where there is no room under; over its foot where there is room for neither (the
  // whole screen). Its left edge is the selection's, kept in the dialog.
  const composerAt = (() => {
    if (!picked || !placed || !room) return undefined;
    const scale = placed.width / frame.width;
    const about = area
      ? {
          left: placed.left + area.x * scale,
          top: placed.top + area.y * scale,
          height: area.height * scale,
        }
      : { left: placed.left, top: placed.top, height: placed.height };
    const width = Math.min(COMPOSER_WIDTH, Math.max(0, room.width - 2 * COMPOSER_GAP));
    const left = Math.max(
      COMPOSER_GAP,
      Math.min(about.left, room.width - width - COMPOSER_GAP)
    );
    if (composerHeight === undefined) return { left, top: 0, width, laid: false };
    const below = about.top + about.height + COMPOSER_GAP;
    const above = about.top - composerHeight - COMPOSER_GAP;
    const under =
      below + composerHeight <= room.height - COMPOSER_GAP
        ? below
        : above >= COMPOSER_GAP
          ? above
          : Math.max(COMPOSER_GAP, room.height - composerHeight - COMPOSER_GAP);
    return { left, top: under, width, laid: true };
  })();

  // The keys go to the dialog and its composer, away from the field that sends them to the remote screen.
  const cancel = useRef(onCancel);
  cancel.current = onCancel;
  const clear = useCallback(() => {
    setPicked(undefined);
    setDraft("");
  }, []);
  const selected = useRef(false);
  selected.current = composing;
  useEffect(() => {
    const element = dialog.current;
    if (!element) return undefined;
    // Escape lets go of what is selected; with nothing selected it puts the frame away.
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      if (selected.current) clear();
      else cancel.current();
    };
    element.addEventListener("keydown", escape);
    return () => element.removeEventListener("keydown", escape);
  }, [clear]);
  // What is typed after a selection is about it: the composer's field has the keys once it is laid by the selection
  // (hidden, as it is while it is measured, it takes no focus). With nothing selected the dialog itself has them.
  const laid = composerAt?.laid === true;
  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (!picked) element.focus({ preventScroll: true });
    else if (laid)
      element
        .querySelector<HTMLElement>('[role="textbox"]')
        ?.focus({ preventScroll: true });
  }, [picked, laid]);

  /** Screen pixels per pixel of the frame, and a pointer's place on the frame (kept to it). */
  const place = (event: PointerEvent) => {
    const matrix = surface.current?.getScreenCTM();
    if (!matrix) return undefined;
    const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(
      matrix.inverse()
    );
    return {
      scale: matrix.a,
      x: Math.min(Math.max(point.x, 0), frame.width),
      y: Math.min(Math.max(point.y, 0), frame.height),
    };
  };
  const boxTo = (at: { x: number; y: number; scale: number }): ScreenMark | undefined =>
    from.current && {
      x: Math.min(from.current.x, at.x),
      y: Math.min(from.current.y, at.y),
      width: Math.abs(at.x - from.current.x),
      height: Math.abs(at.y - from.current.y),
      line: MARK_LINE / at.scale,
    };

  const onPointerDown = (event: PointerEvent<SVGSVGElement>) => {
    if (event.button !== 0 || from.current) return;
    const at = place(event);
    if (!at) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    from.current = { x: at.x, y: at.y, pointer: event.pointerId };
  };
  const onPointerMove = (event: PointerEvent<SVGSVGElement>) => {
    if (from.current?.pointer !== event.pointerId) return;
    const at = place(event);
    if (at) setDrawing(boxTo(at));
  };
  const onPointerUp = (event: PointerEvent<SVGSVGElement>) => {
    if (from.current?.pointer !== event.pointerId) return;
    const at = place(event);
    const box = at && boxTo(at);
    from.current = undefined;
    setDrawing(undefined);
    if (!box || !at) return;
    const longer = Math.max(box.width, box.height) * at.scale;
    const shorter = Math.min(box.width, box.height) * at.scale;
    // A new selection takes the place of the one before: what was written stays, for the new one.
    if (shorter >= SHORTEST_DRAG) setPicked({ area: box });
    else if (longer < SHORTEST_DRAG) setPicked({ area: undefined });
  };
  const onPointerCancel = () => {
    from.current = undefined;
    setDrawing(undefined);
  };

  const ask = (note: string) => {
    if (!picked) return;
    const part = area ? framePart(frame, area) : frame;
    onAsk({
      picture: part ? screenFramePng(part) : Promise.resolve(undefined),
      thumbnail: framePart(frame, area, TILE_EDGE)?.toDataURL("image/png"),
      note,
    });
    // It is the chat's now: the frame stays held for the next selection.
    clear();
  };
  // The box being dragged, or the area selected: one at a time. A CSS pixel on the frame, as it was drawn.
  const box = drawing ?? area;
  const boxPixel = box ? box.line / MARK_LINE : 1;
  // With nothing selected: how to select, in the room over the picture (a device's buttons and the bars are under it).
  const over = placed ? Math.max(0, placed.top) : undefined;
  return (
    <dialog
      aria-label={messages.remote_screen_ask_comma()}
      className="comma-remote-screen-mark"
      data-testid="remote-screen-mark"
      open
      ref={dialog}
      style={{ top }}
      tabIndex={-1}
    >
      {/* (the frame itself, where no stage shows it) */}
      <div className="comma-remote-screen-mark-frame" ref={shown} />
      <div
        className="comma-remote-screen-mark-picture"
        style={placed ?? { visibility: "hidden" }}
      >
        <svg
          aria-hidden
          className="comma-remote-screen-mark-surface"
          data-testid="remote-screen-mark-surface"
          onPointerCancel={onPointerCancel}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          preserveAspectRatio="xMidYMid meet"
          ref={surface}
          viewBox={`0 0 ${frame.width} ${frame.height}`}
        >
          {/* What is drawn stays on the screen: a device's rounds its corners. */}
          <clipPath id={clip}>
            <path d={screenPath(frame.width, frame.height, corners)} />
          </clipPath>
          <g clipPath={`url(#${clip})`}>
            {box ? (
              <>
                <path
                  className="comma-remote-screen-mark-edge"
                  d={markPath(box, (MARK_EDGE * boxPixel) / 2)}
                  strokeWidth={MARK_EDGE * boxPixel}
                />
                {/* (its line is inside it, as a border is: what is boxed is what is cut from the frame) */}
                <path
                  data-testid={drawing ? undefined : "remote-screen-mark-selected"}
                  d={markPath(box, -box.line / 2)}
                  strokeWidth={box.line}
                />
              </>
            ) : wholeMark ? (
              <path
                className="comma-remote-screen-mark-whole"
                data-testid="remote-screen-mark-selected"
                d={screenPath(
                  frame.width,
                  frame.height,
                  corners,
                  wholeMark.line / 2,
                  wholeMark.line * 1.5
                )}
                strokeWidth={wholeMark.line}
              />
            ) : null}
          </g>
        </svg>
      </div>
      {composing ? (
        <div
          className="comma-remote-screen-mark-composer"
          data-testid="remote-screen-mark-composer"
          ref={composer}
          style={
            composerAt
              ? {
                  left: composerAt.left,
                  top: composerAt.top,
                  width: composerAt.width,
                  visibility: composerAt.laid ? undefined : "hidden",
                }
              : { visibility: "hidden" }
          }
        >
          <Composer
            draftSource={draftSource}
            onDraftChange={setDraft}
            onSend={(message) => ask(message.trim())}
            placeholder={messages.remote_screen_mark_hint()}
            submitDisabled={false}
            toolbarLeading={
              <MarkComposerAction
                label={messages.remote_screen_mark_cancel()}
                onPress={clear}
              >
                <CrossLargeIcon aria-hidden className="size-4" />
              </MarkComposerAction>
            }
            variant="compact"
          />
        </div>
      ) : over === undefined ? null : (
        <p className="comma-remote-screen-mark-hint" style={{ height: over }}>
          {messages.remote_screen_inspect_hint()}
        </p>
      )}
    </dialog>
  );
}
