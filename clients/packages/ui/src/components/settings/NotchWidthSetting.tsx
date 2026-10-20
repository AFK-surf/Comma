/* oxlint-disable jsx-a11y/prefer-tag-over-role -- the slider field drives a live preview; a range input cannot draw it. */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent,
} from "react";
import { Button } from "../Button";
import { CommaLogoAnimation } from "../comma-mascot";
import { ResetIcon } from "../icons";
import { Tooltip } from "../tooltip";
import { uiClock, type CancelUiTimer } from "../../clock";
import {
  createSpring,
  placeSpring,
  retargetSpring,
  springAtRest,
  springStateAt,
  type Spring,
} from "../../motion";
import { isReducedMotionEnabled, motionNotchResize } from "../../tokens";
import { cx } from "../utils";

/**
 * The compact Notch as NotchKit lays it out, in points. The physical notch is
 * a MacBook Pro's; the reader's own may differ by a few points.
 */
const notch = {
  width: 185,
  height: 32,
  /** NotchConfiguration.compactContentInsets. */
  inset: 8,
  /** The shell's top flare: compact corner radius 12 x top ratio 0.5. */
  shoulder: 6,
  /** The activity mark (20) and its spacing (10), ahead of the title. */
  mark: 30,
  /** Below this a title shows too few letters; NotchHost drops it too. */
  minimumTitle: 36,
} as const;

/**
 * Screen the preview shows at rest, in points. A Notch wider than this view
 * pulls the view back, the way a camera keeps its subject in frame, so the
 * whole shell and its content stay visible at every width.
 */
const restingViewPoints = 640;
/** Menu bar kept beside the widest Notch once the view pulls back. */
const viewMargin = 14;
const stageHeight = 120;

/** How close to the default a drag lands on it. */
const detentDistance = 4;
/** How far past a limit a drag can pull the width, however hard. */
const rubberBandDistance = 12;
/**
 * How far the field stretches at that furthest pull, as a share of the range:
 * about 2% of its length, which stays inside the gap to the next button.
 */
const fieldStretch = 0.3;
const keyStep = 4;
const keyPageStep = 16;
/** A held key keeps moving the preview; the write waits for it to stop. */
const keyCommitDelayMs = 400;

// The spring's state at a frame is computed from the time since it started
// (../../motion): the curve is the same at any frame rate.
const springRestDistance = 0.1;
const springRestVelocity = 2;

export interface NotchWidthSettingLabels {
  /** The slider's name, shown inside it. */
  width: string;
  reset: string;
  /** Shows the width on the real Notch once. */
  preview: string;
  /** Spoken value of the slider, such as "156 pt on each side". */
  valueText: (value: number) => string;
  /** The running Task title the preview shows beside the notch. */
  sampleTitle: string;
}

export interface NotchWidthSettingProps {
  /** Points the compact Notch reaches past each side of the physical notch. */
  value: number;
  defaultValue: number;
  min: number;
  max: number;
  disabled?: boolean;
  labels: NotchWidthSettingLabels;
  /** Called once a resize settles: on release, or after arrow keys stop. */
  onValueCommit: (value: number) => void;
  /** Shows a width on the real Notch; without it there is no such action. */
  onPreview?: (value: number) => void;
  className?: string;
}

interface Drag {
  pointerId: number;
  /** The field's box when the drag began: where `min` sits, and its scale. */
  originX: number;
  pointsPerPixel: number;
  lastTime: number;
  lastWidth: number;
  velocity: number;
  width: number;
  /** Where a release now lands: `width` rounded and held inside the range. */
  settled: number;
}

interface SpringMotion {
  spring: Spring;
  frame: CancelUiTimer | null;
}

const clamp = (value: number, min: number, max: number) =>
  Math.min(max, Math.max(min, value));

/** Pull past a limit gives less and less, the way a scroll view stretches. */
const rubberBand = (distance: number) =>
  (1 - 1 / ((distance * 0.55) / rubberBandDistance + 1)) * rubberBandDistance;

/**
 * Live preview of the compact Notch over a menu bar, sized by a slider field
 * beneath it. Motion is written straight to the preview and the field each
 * frame, so no React render runs while either moves.
 */
export const NotchWidthSetting = ({
  value,
  defaultValue,
  min,
  max,
  disabled = false,
  labels,
  onValueCommit,
  onPreview,
  className,
}: NotchWidthSettingProps) => {
  const rootRef = useRef<HTMLDivElement>(null);
  const screenRef = useRef<HTMLDivElement>(null);
  const shellRef = useRef<HTMLDivElement>(null);
  const fieldRef = useRef<HTMLDivElement>(null);
  const fillRef = useRef<HTMLSpanElement>(null);
  const readoutRef = useRef<HTMLSpanElement>(null);
  const dragRef = useRef<Drag | null>(null);
  const springRef = useRef<SpringMotion>({
    spring: createSpring(motionNotchResize, value, 0),
    frame: null,
  });
  const keyCommitRef = useRef<{ timer: CancelUiTimer; value: number } | null>(null);
  const committedRef = useRef(value);
  // Timers and the unmount flush call the owner's latest callback.
  const onValueCommitRef = useRef(onValueCommit);
  useLayoutEffect(() => {
    onValueCommitRef.current = onValueCommit;
  });
  const [spokenValue, setSpokenValue] = useState(value);

  const paint = useCallback(
    (width: number) => {
      const screen = screenRef.current;
      const shell = shellRef.current;
      const field = fieldRef.current;
      const fill = fillRef.current;
      const readout = readoutRef.current;
      if (!screen || !shell || !field || !fill || !readout) return;

      const outer = (width + notch.inset) * 2 + notch.width;
      shell.style.width = `calc(${outer} * var(--notch-pt))`;
      const view = String(
        Math.max(restingViewPoints, outer + 2 * (notch.shoulder + viewMargin))
      );
      if (screen.style.getPropertyValue("--notch-view-points") !== view) {
        screen.style.setProperty("--notch-view-points", view);
      }
      const titled = width - notch.mark >= notch.minimumTitle ? "true" : "false";
      if (shell.dataset.titled !== titled) shell.dataset.titled = titled;

      const fraction = (clamp(width, min, max) - min) / (max - min);
      fill.style.transform = `scaleX(${fraction})`;
      // The value rewrites its one text node. Setting textContent would insert
      // a new node on every frame of a drag, which can make style rules that
      // depend on descendants restyle whole ancestors.
      const shown = String(Math.round(clamp(width, min, max)));
      const text =
        readout.firstChild ?? readout.appendChild(document.createTextNode(""));
      if (text.nodeValue !== shown) text.nodeValue = shown;

      // Pulled past an end, the field stretches away from the other end and
      // thins a little, then gives it back as the width returns.
      const overshoot = width > max ? width - max : width < min ? min - width : 0;
      const stretch = 1 + (overshoot / (max - min)) * fieldStretch;
      const transform =
        overshoot > 0 ? `scale(${stretch}, ${1 - (stretch - 1) / 2})` : "";
      if (field.style.transform !== transform) {
        field.style.transformOrigin = width < min ? "right center" : "left center";
        field.style.transform = transform;
      }
    },
    [max, min]
  );

  const setSnapped = useCallback((snapped: boolean) => {
    const root = rootRef.current;
    const next = snapped ? "true" : "false";
    if (root && root.dataset.snapped !== next) root.dataset.snapped = next;
  }, []);

  // Written like the snap, so taking and letting go of the field renders nothing.
  const setDragging = useCallback((dragging: boolean) => {
    const root = rootRef.current;
    if (root) root.dataset.dragging = dragging ? "true" : "false";
  }, []);

  const step = useCallback(
    (now: number) => {
      const motion = springRef.current;
      motion.frame = null;
      const { spring } = motion;
      const state = springStateAt(spring, now);
      if (springAtRest(state, spring.target, springRestDistance, springRestVelocity)) {
        placeSpring(spring, now, spring.target);
        paint(spring.target);
        return;
      }
      paint(state.position);
      motion.frame = uiClock.frame(step);
    },
    [paint]
  );

  const animateTo = useCallback(
    (target: number, velocity?: number) => {
      const motion = springRef.current;
      const now = uiClock.monotonic();
      if (isReducedMotionEnabled()) {
        motion.frame?.();
        motion.frame = null;
        placeSpring(motion.spring, now, target);
        paint(target);
        return;
      }
      retargetSpring(motion.spring, now, target, velocity);
      motion.frame ??= uiClock.frame(step);
    },
    [paint, step]
  );

  const commit = useCallback((next: number) => {
    if (next === committedRef.current) return;
    committedRef.current = next;
    onValueCommitRef.current(next);
  }, []);

  const flushKeyCommit = useCallback(() => {
    const pending = keyCommitRef.current;
    if (!pending) return;
    pending.timer();
    keyCommitRef.current = null;
    commit(pending.value);
  }, [commit]);

  // The first paint already has the saved width; later values glide to theirs.
  const paintedRef = useRef(false);
  useLayoutEffect(() => {
    committedRef.current = value;
    if (dragRef.current || keyCommitRef.current) return;
    setSpokenValue(value);
    if (!paintedRef.current) {
      paintedRef.current = true;
      placeSpring(springRef.current.spring, uiClock.monotonic(), value);
      paint(value);
      return;
    }
    animateTo(value);
  }, [animateTo, paint, value]);

  useEffect(
    () => () => {
      springRef.current.frame?.();
      flushKeyCommit();
      // Settings closing under a held drag keeps the width it was dragged to.
      const drag = dragRef.current;
      dragRef.current = null;
      if (drag) commit(drag.settled);
    },
    [commit, flushKeyCommit]
  );

  /** A pulled width, stretched past a limit and held on the default near it. */
  const shape = (pulled: number) => {
    if (pulled < min) {
      return {
        snapped: false,
        width: isReducedMotionEnabled() ? min : min - rubberBand(min - pulled),
      };
    }
    if (pulled > max) {
      return {
        snapped: false,
        width: isReducedMotionEnabled() ? max : max + rubberBand(pulled - max),
      };
    }
    if (Math.abs(pulled - defaultValue) <= detentDistance) {
      return { snapped: true, width: defaultValue };
    }
    return { snapped: false, width: pulled };
  };

  const handlePointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled || dragRef.current || event.button !== 0) return;
    const field = fieldRef.current;
    if (!field) return;
    flushKeyCommit();

    const box = field.getBoundingClientRect();
    const pointsPerPixel = (max - min) / box.width;
    const pointed = min + (event.clientX - box.left) * pointsPerPixel;
    const current = springStateAt(
      springRef.current.spring,
      uiClock.monotonic()
    ).position;
    const drag: Drag = {
      lastTime: uiClock.monotonic(),
      lastWidth: current,
      originX: box.left,
      pointerId: event.pointerId,
      pointsPerPixel,
      settled: clamp(Math.round(current), min, max),
      velocity: 0,
      width: current,
    };
    dragRef.current = drag;
    // Captured on press, so the release always reaches the field, even after
    // a quick flick leaves it before the first move.
    field.setPointerCapture(event.pointerId);
    // The press itself sets the width there; the fill glides over to it.
    const { snapped, width } = shape(clamp(pointed, min, max));
    drag.width = width;
    drag.settled = clamp(Math.round(width), min, max);
    setSnapped(snapped);
    animateTo(width);
    setDragging(true);
  };

  const handlePointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const pulled = min + (event.clientX - drag.originX) * drag.pointsPerPixel;
    const { snapped, width } = shape(pulled);
    const now = uiClock.monotonic();
    const elapsed = now - drag.lastTime;
    if (elapsed > 0) {
      // Smoothed, so one uneven frame cannot fling the release.
      const instant = ((width - drag.lastWidth) / elapsed) * 1000;
      drag.velocity = drag.velocity * 0.6 + instant * 0.4;
    }
    drag.lastTime = now;
    drag.lastWidth = width;
    drag.width = width;
    drag.settled = clamp(Math.round(width), min, max);
    setSnapped(snapped);
    const { spring, frame } = springRef.current;
    if (frame) {
      // The glide from the press is still under way; it chases the pointer.
      retargetSpring(spring, now, width);
      return;
    }
    placeSpring(spring, now, width);
    paint(width);
  };

  const endDrag = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || event.pointerId !== drag.pointerId) return;
    dragRef.current = null;
    if (fieldRef.current?.hasPointerCapture(event.pointerId)) {
      fieldRef.current.releasePointerCapture(event.pointerId);
    }
    setDragging(false);
    setSnapped(false);
    const { settled } = drag;
    // A release past an end springs back with the drag's own momentum.
    animateTo(settled, settled === drag.width ? undefined : drag.velocity);
    setSpokenValue(settled);
    commit(settled);
  };

  const reset = () => {
    keyCommitRef.current?.timer();
    keyCommitRef.current = null;
    animateTo(defaultValue);
    setSpokenValue(defaultValue);
    commit(defaultValue);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (disabled || dragRef.current) return;
    const from = keyCommitRef.current?.value ?? springRef.current.spring.target;
    const coarse = event.shiftKey ? keyPageStep : keyStep;
    let next: number;
    switch (event.key) {
      case "ArrowRight":
      case "ArrowUp":
        next = from + coarse;
        break;
      case "ArrowLeft":
      case "ArrowDown":
        next = from - coarse;
        break;
      case "PageUp":
        next = from + keyPageStep;
        break;
      case "PageDown":
        next = from - keyPageStep;
        break;
      case "Home":
        next = min;
        break;
      case "End":
        next = max;
        break;
      default:
        return;
    }
    event.preventDefault();
    next = clamp(Math.round(next), min, max);
    animateTo(next);
    setSpokenValue(next);
    keyCommitRef.current?.timer();
    keyCommitRef.current = {
      timer: uiClock.after(keyCommitDelayMs, () => {
        keyCommitRef.current = null;
        commit(next);
      }),
      value: next,
    };
  };

  const previewOnNotch = () => {
    // The real Notch shows the width the reader sees here, saved first.
    const width =
      keyCommitRef.current?.value ?? Math.round(springRef.current.spring.target);
    flushKeyCommit();
    onPreview?.(clamp(width, min, max));
  };

  const resettable = !disabled && value !== defaultValue;

  return (
    <div
      className={cx("comma-notch-width", className)}
      data-disabled={disabled ? "true" : undefined}
      data-slot="notch-width-setting"
      ref={rootRef}
      style={
        {
          "--notch-default-fraction": (defaultValue - min) / (max - min),
          "--notch-stage-ratio": `${restingViewPoints} / ${stageHeight}`,
        } as CSSProperties
      }
    >
      <div aria-hidden="true" className="comma-notch-width__stage">
        <div className="comma-notch-width__screen" ref={screenRef}>
          <div className="comma-notch-width__window">
            <span className="comma-notch-width__lights">
              <span />
              <span />
              <span />
            </span>
          </div>
          <div className="comma-notch-width__menubar">
            <span className="comma-notch-width__menus">
              <span className="comma-notch-width__glyph" />
              <span className="comma-notch-width__menu" data-app="true" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
            </span>
            <span className="comma-notch-width__status">
              <span className="comma-notch-width__glyph" />
              <span className="comma-notch-width__glyph" />
              <span className="comma-notch-width__glyph" data-battery="true" />
              <span className="comma-notch-width__menu" data-clock="true" />
            </span>
          </div>
          <div className="comma-notch-width__shell" data-titled="true" ref={shellRef}>
            <span className="comma-notch-width__leading">
              <CommaLogoAnimation className="comma-notch-width__mark" size={14} />
              <span className="comma-notch-width__title">{labels.sampleTitle}</span>
            </span>
            <span className="comma-notch-width__camera" />
            <span className="comma-notch-width__count">1</span>
          </div>
        </div>
      </div>

      <div className="comma-notch-width__control">
        <div
          aria-disabled={disabled ? true : undefined}
          aria-label={labels.width}
          aria-orientation="horizontal"
          aria-valuemax={max}
          aria-valuemin={min}
          aria-valuenow={spokenValue}
          aria-valuetext={labels.valueText(spokenValue)}
          className="comma-notch-width__field"
          onBlur={flushKeyCommit}
          onKeyDown={handleKeyDown}
          onLostPointerCapture={endDrag}
          onPointerCancel={endDrag}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={endDrag}
          ref={fieldRef}
          role="slider"
          tabIndex={disabled ? -1 : 0}
        >
          <span aria-hidden="true" className="comma-notch-width__track">
            <span className="comma-notch-width__fill" ref={fillRef} />
            <span className="comma-notch-width__detent" />
          </span>
          <span aria-hidden="true" className="comma-notch-width__label">
            {labels.width}
          </span>
          <span
            aria-hidden="true"
            className="comma-notch-width__readout"
            ref={readoutRef}
          />
        </div>
        <Tooltip content={labels.reset}>
          <Button
            aria-label={labels.reset}
            className="comma-notch-width__reset"
            disabled={!resettable}
            hierarchy="secondary-gray"
            iconLeading={<ResetIcon />}
            iconOnly
            onPress={reset}
            size="sm"
          />
        </Tooltip>
        {onPreview ? (
          <Button
            disabled={disabled}
            hierarchy="secondary-gray"
            onPress={previewOnNotch}
            size="sm"
          >
            {labels.preview}
          </Button>
        ) : null}
      </div>
    </div>
  );
};
