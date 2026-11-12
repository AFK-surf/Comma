import { useCommaMessages } from "@comma/i18n/react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { motionDuration } from "@comma/ui/tokens";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent,
} from "react";

/** How long a screenshot stays in its corner, unless the pointer is on it or it is being dragged. */
export const SCREEN_SHOT_STAYS_MS = 5_000;

/** A screenshot just taken: its PNG and its file's name. `id` tells one from the next. */
export type ScreenShot = { id: number; png: Blob; name: string };

/** A place in the panel, in CSS pixels from its corner. */
type Place = { left: number; top: number; width: number; height: number };

/**
 * Where the screen's picture shows in the panel, and the shape of its corners: a device's panel in its case, else the
 * picture as the `<video>` fits it. Undefined while it shows none.
 */
function pictureIn(
  panel: Element,
  video: HTMLVideoElement | null
): (Place & { radius: string }) | undefined {
  if (!video) return undefined;
  const device = video.closest(".comma-remote-screen-device-screen");
  const origin = panel.getBoundingClientRect();
  const box = (device ?? video).getBoundingClientRect();
  if (!(box.width > 0 && box.height > 0)) return undefined;
  const radius = getComputedStyle(device ?? video).borderRadius;
  if (device || !(video.videoWidth > 0 && video.videoHeight > 0))
    return {
      left: box.left - origin.left,
      top: box.top - origin.top,
      width: box.width,
      height: box.height,
      radius,
    };
  // (a plain `<video>` is larger than the picture it fits)
  const scale = Math.min(box.width / video.videoWidth, box.height / video.videoHeight);
  const width = video.videoWidth * scale;
  const height = video.videoHeight * scale;
  return {
    left: box.left - origin.left + (box.width - width) / 2,
    top: box.top - origin.top + (box.height - height) / 2,
    width,
    height,
    radius,
  };
}

/**
 * The shutter: the screen's picture goes white for a moment as Take screenshot is pressed, before the picture has
 * come back from the device. `shot` counts the presses: each one flashes again.
 */
export function ScreenShutter({
  shot,
  panel,
  picture,
}: {
  shot: number;
  panel(): Element | null;
  picture(): HTMLVideoElement | null;
}) {
  const [at, setAt] = useState<(Place & { radius: string }) | undefined>();
  // (where the picture is as it is pressed: the panel's elements are read then, not followed)
  const read = useRef({ panel, picture });
  read.current = { panel, picture };
  useLayoutEffect(() => {
    const within = read.current.panel();
    setAt(shot > 0 && within ? pictureIn(within, read.current.picture()) : undefined);
  }, [shot]);
  if (!at) return null;
  const { radius, ...place } = at;
  return (
    <div
      aria-hidden
      className="comma-remote-screen-shutter"
      key={shot}
      style={{ ...place, borderRadius: radius }}
    />
  );
}

/**
 * A screenshot just taken, in the corner of the stage: it comes from where the screen's picture shows, stays
 * `SCREEN_SHOT_STAYS_MS`, and goes. Pressed, it is asked about (`onAsk`); dragged, it is a file, for the chat's
 * composer or anything else that takes one. The pointer on it, or a drag of it, holds it there.
 */
export function ScreenShotThumb({
  shot,
  panel,
  stage,
  picture,
  onAsk,
  onGone,
}: {
  shot: ScreenShot;
  panel(): Element | null;
  /** The stage whose corner it lies in. */
  stage(): Element | null;
  picture(): HTMLVideoElement | null;
  /** Absent where there is no chat to ask: it is then a picture to drag, and no button. */
  onAsk?: (() => void) | undefined;
  onGone(): void;
}) {
  const messages = useCommaMessages();
  const url = useMemo(() => URL.createObjectURL(shot.png), [shot.png]);
  useEffect(() => () => URL.revokeObjectURL(url), [url]);
  const thumb = useRef<HTMLDivElement>(null);
  const [corner, setCorner] = useState<{ right: number; bottom: number } | undefined>();
  const [from, setFrom] = useState<CSSProperties | undefined>();
  const [leaving, setLeaving] = useState(false);
  // (the panel's own elements: they are the same for as long as it shows)
  const read = useRef({ panel, stage, picture });
  read.current = { panel, stage, picture };

  // Its corner: the stage's lower right, wherever the bars under the stage end.
  useLayoutEffect(() => {
    const within = read.current.panel();
    const on = read.current.stage();
    if (!within || !on) return undefined;
    const place = () => {
      const all = within.getBoundingClientRect();
      const box = on.getBoundingClientRect();
      setCorner({ right: all.right - box.right, bottom: all.bottom - box.bottom });
    };
    place();
    const observer = new ResizeObserver(place);
    observer.observe(within);
    observer.observe(on);
    return () => observer.disconnect();
  }, []);

  // It lands from where the screen's picture shows: measured once it lies in its corner, before it is painted.
  const [sized, setSized] = useState(false);
  useLayoutEffect(() => {
    const element = thumb.current;
    const within = read.current.panel();
    if (!element || !within || !corner || !sized || from) return;
    const shown = pictureIn(within, read.current.picture());
    const lies = element.getBoundingClientRect();
    const origin = within.getBoundingClientRect();
    if (!shown || !(lies.width > 0)) return setFrom({});
    setFrom({
      "--comma-remote-screen-shot-x": `${shown.left - (lies.left - origin.left)}px`,
      "--comma-remote-screen-shot-y": `${shown.top - (lies.top - origin.top)}px`,
      "--comma-remote-screen-shot-scale": String(shown.width / lies.width),
    } as CSSProperties);
  }, [corner, sized, from]);

  // It stays a while, then goes; the pointer on it or a drag of it holds it.
  const going = useRef<CancelUiTimer | undefined>(undefined);
  const gone = useRef(onGone);
  gone.current = onGone;
  const hold = useCallback(() => {
    going.current?.();
    going.current = undefined;
  }, []);
  const leave = useCallback(() => {
    hold();
    setLeaving(true);
    going.current = uiClock.after(motionDuration.pictureInPictureExit, () =>
      gone.current()
    );
  }, [hold]);
  const stay = useCallback(() => {
    hold();
    going.current = uiClock.after(SCREEN_SHOT_STAYS_MS, leave);
  }, [hold, leave]);
  useEffect(() => {
    stay();
    return hold;
  }, [hold, stay]);

  const onDragStart = (event: DragEvent<HTMLElement>) => {
    hold();
    event.dataTransfer.effectAllowed = "copy";
    event.dataTransfer.items.add(
      new File([shot.png], shot.name, { type: "image/png" })
    );
    const image = event.currentTarget.querySelector("img");
    if (image)
      event.dataTransfer.setDragImage(image, image.width / 2, image.height / 2);
  };
  // (taken by what it was dropped on: it has gone there; dropped on nothing, it stays its while again)
  const onDragEnd = (event: DragEvent<HTMLElement>) =>
    event.dataTransfer.dropEffect === "none" ? stay() : gone.current();

  const label = `${messages.remote_screen_ask_comma()}: ${shot.name}`;
  const image = (
    <img
      alt={onAsk ? "" : shot.name}
      draggable={false}
      onLoad={() => setSized(true)}
      src={url}
    />
  );
  return (
    <div
      className="comma-remote-screen-shot"
      data-landing={from ? "true" : undefined}
      data-leaving={leaving || undefined}
      data-testid="remote-screen-shot"
      draggable
      onDragEnd={onDragEnd}
      onDragStart={onDragStart}
      onPointerEnter={hold}
      onPointerLeave={() => {
        if (!leaving) stay();
      }}
      ref={thumb}
      style={{ ...corner, ...from, visibility: from ? undefined : "hidden" }}
    >
      {onAsk ? (
        <button
          aria-label={label}
          onBlur={() => {
            if (!leaving) stay();
          }}
          onClick={() => {
            hold();
            onAsk();
          }}
          onFocus={hold}
          type="button"
        >
          {image}
        </button>
      ) : (
        image
      )}
    </div>
  );
}
