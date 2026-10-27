/* oxlint-disable jsx-a11y/prefer-tag-over-role -- the slider field drives a live preview; a range input cannot draw it. */
import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
  type Ref,
} from "react";
import { Button } from "../Button";
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

/** A held key keeps moving the value; the write waits for it to stop. */
const keyCommitDelayMs = 400;
/**
 * How far the field stretches at the furthest pull past an end, as a share of
 * the range: about 2% of its length, which stays inside the gap to the next
 * button.
 */
const fieldStretch = 0.3;

// The spring's state at a frame is computed from the time since it started
// (../../motion): the curve is the same at any frame rate.
const springRestDistance = 0.1;
const springRestVelocity = 2;

export interface SettingsSliderFieldProps {
  value: number;
  defaultValue: number;
  min: number;
  max: number;
  disabled?: boolean;
  /** The slider's name, shown inside it. */
  label: string;
  /** Name of the button that returns the value to `defaultValue`. */
  resetLabel: string;
  /** Spoken value of the slider, such as "156 pt on each side". */
  valueText: (value: number) => string;
  /** The value shown inside the field. Defaults to the number itself. */
  formatValue?: (value: number) => string;
  keyStep?: number;
  /** Shift+arrow and Page Up/Down. */
  keyPageStep?: number;
  /** How close to the default a drag lands on it. */
  detentDistance?: number;
  /** How far past a limit a drag can pull the value, however hard. */
  rubberBandDistance?: number;
  /** Called once a change settles: on release, or after arrow keys stop. */
  onValueCommit: (value: number) => void;
  /**
   * Called with the value the field shows on every frame of a drag or glide,
   * so a preview can follow it without a React render. It may run past `min`
   * or `max` while a drag pulls beyond them.
   */
  onPaint?: (value: number) => void;
  /** Controls after the reset button. */
  trailing?: ReactNode;
  /** Reads the field from a trailing control's action. */
  handleRef?: Ref<SettingsSliderFieldHandle>;
  className?: string;
}

export interface SettingsSliderFieldHandle {
  /** Saves a value still waiting on arrow keys and returns the value shown. */
  settledValue: () => number;
}

interface Drag {
  pointerId: number;
  /** The field's box when the drag began: where `min` sits, and its scale. */
  originX: number;
  unitsPerPixel: number;
  lastTime: number;
  lastValue: number;
  velocity: number;
  current: number;
  /** Where a release now lands: `current` rounded and held inside the range. */
  settled: number;
}

interface SpringMotion {
  spring: Spring;
  frame: CancelUiTimer | null;
}

const clamp = (value: number, min: number, max: number) =>
  Math.min(max, Math.max(min, value));

/**
 * A slider drawn as a field, as in an inspector: its name and value sit
 * inside, its fill is the value, and it can be taken anywhere along it. A
 * drag past an end rubber-bands, a drag near the default holds on it, and a
 * release, a reset or an arrow key glides to the value on a spring. Motion is
 * written straight to the field each frame, so no React render runs while it
 * moves.
 */
export const SettingsSliderField = ({
  value,
  defaultValue,
  min,
  max,
  disabled = false,
  label,
  resetLabel,
  valueText,
  formatValue = String,
  keyStep = 4,
  keyPageStep = 16,
  detentDistance = 4,
  rubberBandDistance = 12,
  onValueCommit,
  onPaint,
  trailing,
  handleRef,
  className,
}: SettingsSliderFieldProps) => {
  const rootRef = useRef<HTMLDivElement>(null);
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
  // Timers, frames and the unmount flush call the owner's latest callbacks.
  const onValueCommitRef = useRef(onValueCommit);
  const onPaintRef = useRef(onPaint);
  const formatValueRef = useRef(formatValue);
  useLayoutEffect(() => {
    onValueCommitRef.current = onValueCommit;
    onPaintRef.current = onPaint;
    formatValueRef.current = formatValue;
  });
  const [spokenValue, setSpokenValue] = useState(value);

  /** Pull past a limit gives less and less, the way a scroll view stretches. */
  const rubberBand = useCallback(
    (distance: number) =>
      (1 - 1 / ((distance * 0.55) / rubberBandDistance + 1)) * rubberBandDistance,
    [rubberBandDistance]
  );

  const paint = useCallback(
    (current: number) => {
      const field = fieldRef.current;
      const fill = fillRef.current;
      const readout = readoutRef.current;
      if (!field || !fill || !readout) return;

      const fraction = (clamp(current, min, max) - min) / (max - min);
      fill.style.transform = `scaleX(${fraction})`;
      // The value rewrites its one text node. Setting textContent would insert
      // a new node on every frame of a drag, which can make style rules that
      // depend on descendants restyle whole ancestors.
      const shown = formatValueRef.current(Math.round(clamp(current, min, max)));
      const text =
        readout.firstChild ?? readout.appendChild(document.createTextNode(""));
      if (text.nodeValue !== shown) text.nodeValue = shown;

      // Pulled past an end, the field stretches away from the other end and
      // thins a little, then gives it back as the value returns.
      const overshoot =
        current > max ? current - max : current < min ? min - current : 0;
      const stretch = 1 + (overshoot / (max - min)) * fieldStretch;
      const transform =
        overshoot > 0 ? `scale(${stretch}, ${1 - (stretch - 1) / 2})` : "";
      if (field.style.transform !== transform) {
        field.style.transformOrigin = current < min ? "right center" : "left center";
        field.style.transform = transform;
      }
      onPaintRef.current?.(current);
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

  // The first paint already has the saved value; later values glide to theirs.
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
      // Settings closing under a held drag keeps the value it was dragged to.
      const drag = dragRef.current;
      dragRef.current = null;
      if (drag) commit(drag.settled);
    },
    [commit, flushKeyCommit]
  );

  /** A pulled value, stretched past a limit and held on the default near it. */
  const shape = (pulled: number) => {
    if (pulled < min) {
      return {
        snapped: false,
        current: isReducedMotionEnabled() ? min : min - rubberBand(min - pulled),
      };
    }
    if (pulled > max) {
      return {
        snapped: false,
        current: isReducedMotionEnabled() ? max : max + rubberBand(pulled - max),
      };
    }
    if (Math.abs(pulled - defaultValue) <= detentDistance) {
      return { snapped: true, current: defaultValue };
    }
    return { snapped: false, current: pulled };
  };

  const handlePointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled || dragRef.current || event.button !== 0) return;
    const field = fieldRef.current;
    if (!field) return;
    flushKeyCommit();

    const box = field.getBoundingClientRect();
    const unitsPerPixel = (max - min) / box.width;
    const pointed = min + (event.clientX - box.left) * unitsPerPixel;
    const position = springStateAt(
      springRef.current.spring,
      uiClock.monotonic()
    ).position;
    const drag: Drag = {
      current: position,
      lastTime: uiClock.monotonic(),
      lastValue: position,
      originX: box.left,
      pointerId: event.pointerId,
      settled: clamp(Math.round(position), min, max),
      unitsPerPixel,
      velocity: 0,
    };
    dragRef.current = drag;
    // Captured on press, so the release always reaches the field, even after
    // a quick flick leaves it before the first move.
    field.setPointerCapture(event.pointerId);
    // The press itself sets the value there; the fill glides over to it.
    const { snapped, current } = shape(clamp(pointed, min, max));
    drag.current = current;
    drag.settled = clamp(Math.round(current), min, max);
    setSnapped(snapped);
    animateTo(current);
    setDragging(true);
  };

  const handlePointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const pulled = min + (event.clientX - drag.originX) * drag.unitsPerPixel;
    const { snapped, current } = shape(pulled);
    const now = uiClock.monotonic();
    const elapsed = now - drag.lastTime;
    if (elapsed > 0) {
      // Smoothed, so one uneven frame cannot fling the release.
      const instant = ((current - drag.lastValue) / elapsed) * 1000;
      drag.velocity = drag.velocity * 0.6 + instant * 0.4;
    }
    drag.lastTime = now;
    drag.lastValue = current;
    drag.current = current;
    drag.settled = clamp(Math.round(current), min, max);
    setSnapped(snapped);
    const { spring, frame } = springRef.current;
    if (frame) {
      // The glide from the press is still under way; it chases the pointer.
      retargetSpring(spring, now, current);
      return;
    }
    placeSpring(spring, now, current);
    paint(current);
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
    animateTo(settled, settled === drag.current ? undefined : drag.velocity);
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

  const settledValue = useCallback(() => {
    const shown =
      keyCommitRef.current?.value ?? Math.round(springRef.current.spring.target);
    flushKeyCommit();
    return clamp(shown, min, max);
  }, [flushKeyCommit, max, min]);
  useImperativeHandle(handleRef, () => ({ settledValue }), [settledValue]);

  const resettable = !disabled && value !== defaultValue;

  return (
    <div
      className={cx("comma-settings-slider-field", className)}
      data-disabled={disabled ? "true" : undefined}
      data-slot="settings-slider-field"
      ref={rootRef}
      style={
        {
          "--settings-slider-default-fraction": (defaultValue - min) / (max - min),
        } as CSSProperties
      }
    >
      <div
        aria-disabled={disabled ? true : undefined}
        aria-label={label}
        aria-orientation="horizontal"
        aria-valuemax={max}
        aria-valuemin={min}
        aria-valuenow={spokenValue}
        aria-valuetext={valueText(spokenValue)}
        className="comma-settings-slider-field__field"
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
        <span aria-hidden="true" className="comma-settings-slider-field__track">
          <span className="comma-settings-slider-field__fill" ref={fillRef} />
          <span className="comma-settings-slider-field__detent" />
        </span>
        <span aria-hidden="true" className="comma-settings-slider-field__label">
          {label}
        </span>
        <span
          aria-hidden="true"
          className="comma-settings-slider-field__readout"
          ref={readoutRef}
        />
      </div>
      <Tooltip content={resetLabel}>
        <Button
          aria-label={resetLabel}
          className="comma-settings-slider-field__reset"
          disabled={!resettable}
          hierarchy="secondary-gray"
          iconLeading={<ResetIcon />}
          iconOnly
          onPress={reset}
          size="sm"
        />
      </Tooltip>
      {trailing}
    </div>
  );
};
