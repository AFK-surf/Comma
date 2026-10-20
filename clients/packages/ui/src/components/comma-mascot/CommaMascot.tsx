/* oxlint-disable jsx-a11y/prefer-tag-over-role -- The mascot is an interactive vector graphic; replacing it with img would remove its mesh interaction. */
import { uiClock, type CancelUiTimer } from "../../clock";
import {
  createSpring,
  placeSpring,
  retargetSpring,
  springAtRest,
  springStateAt,
  type Spring,
} from "../../motion";
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type PointerEvent as ReactPointerEvent,
  type RefObject,
  type SVGAttributes,
} from "react";
import {
  isReducedMotionEnabled,
  motionMascotElastic,
  subscribeToReducedMotion,
} from "../../tokens/motion";
import { cx } from "../utils";
import {
  blinkCloseDuration,
  blinkOpenDuration,
  eyeMorphDuration,
  eyeMorphEasing,
  eyePoses,
  interpolateEyePose,
  type CommaMascotExpression,
  type EyePose,
} from "./eyeMorph";
import { commaMascotCorePoints, commaMascotOuterPoints } from "./mascotGeometry";
import {
  beginSoftBodyDrag,
  createSoftBodyMesh,
  endSoftBodyDrag,
  moveSoftBodyDrag,
  resetSoftBodyMesh,
  softBodyStepMs,
  stepSoftBodyMesh,
  warpPoint,
  type Point,
  type SoftBodyMesh,
} from "./softBodyMesh";

const VIEWBOX_SIZE = 256;
export const commaMascotMaxGazeDistance = 5.5;
const CORE_SHARP_INDICES = new Set([13, 15]);
const OUTER_SHARP_INDICES = new Set([39, 64]);
const reducedMotionServerSnapshot = () => false;

const closedCurvePath = (
  mesh: SoftBodyMesh,
  source: readonly Point[],
  sharpIndices: ReadonlySet<number> = new Set()
) => {
  const points = source.map((point) => warpPoint(mesh, point));
  if (points.length < 3) {
    return "";
  }
  const first = points[0]!;
  let path = `M ${first.x.toFixed(3)} ${first.y.toFixed(3)}`;
  for (let index = 0; index < points.length; index += 1) {
    const current = points[index]!;
    const next = points[(index + 1) % points.length]!;
    const afterNext = points[(index + 2) % points.length]!;
    const before = points[(index - 1 + points.length) % points.length]!;
    const controlOne = {
      x: current.x + (next.x - before.x) / 6,
      y: current.y + (next.y - before.y) / 6,
    };
    const controlTwo = {
      x: next.x - (afterNext.x - current.x) / 6,
      y: next.y - (afterNext.y - current.y) / 6,
    };
    path +=
      sharpIndices.has(index) || sharpIndices.has((index + 1) % points.length)
        ? ` L ${next.x.toFixed(3)} ${next.y.toFixed(3)}`
        : ` C ${controlOne.x.toFixed(3)} ${controlOne.y.toFixed(3)} ${controlTwo.x.toFixed(3)} ${controlTwo.y.toFixed(3)} ${next.x.toFixed(3)} ${next.y.toFixed(3)}`;
  }
  return `${path} Z`;
};

const pointInContour = (point: Point, contour: readonly Point[]) => {
  let inside = false;
  for (
    let index = 0, previous = contour.length - 1;
    index < contour.length;
    previous = index++
  ) {
    const currentPoint = contour[index]!;
    const previousPoint = contour[previous]!;
    const crossesRay =
      currentPoint.y > point.y !== previousPoint.y > point.y &&
      point.x <
        ((previousPoint.x - currentPoint.x) * (point.y - currentPoint.y)) /
          (previousPoint.y - currentPoint.y) +
          currentPoint.x;
    if (crossesRay) {
      inside = !inside;
    }
  }
  return inside;
};

const isMascotPoint = (point: Point) =>
  pointInContour(point, commaMascotOuterPoints) ||
  pointInContour(point, commaMascotCorePoints);

type EyeAnimation = {
  duration: number;
  from: EyePose;
  onComplete?: (() => void) | undefined;
  startedAt: number;
  to: EyePose;
};

const useEyePose = (expression: CommaMascotExpression, reducedMotion: boolean) => {
  const currentRef = useRef<EyePose>(eyePoses[expression]);
  const animationRef = useRef<EyeAnimation | null>(null);
  const frameRef = useRef<CancelUiTimer | null>(null);
  const blinkTimerRef = useRef<CancelUiTimer | null>(null);
  const [pose, setPose] = useState<EyePose>(eyePoses[expression]);

  const cancelFrame = useCallback(() => {
    if (frameRef.current !== null) {
      frameRef.current();
      frameRef.current = null;
    }
  }, []);

  const animateTo = useCallback(
    (target: EyePose, duration: number, onComplete?: () => void) => {
      cancelFrame();
      if (reducedMotion || duration === 0) {
        currentRef.current = target;
        setPose(target);
        onComplete?.();
        return;
      }
      animationRef.current = {
        duration,
        from: currentRef.current,
        onComplete,
        startedAt: uiClock.monotonic(),
        to: target,
      };

      const tick = (now: number) => {
        const animation = animationRef.current;
        if (!animation) {
          frameRef.current = null;
          return;
        }
        const progress = Math.min((now - animation.startedAt) / animation.duration, 1);
        const next = interpolateEyePose(
          animation.from,
          animation.to,
          eyeMorphEasing(progress)
        );
        currentRef.current = next;
        setPose(next);
        if (progress < 1) {
          frameRef.current = uiClock.frame(tick);
          return;
        }
        animationRef.current = null;
        frameRef.current = null;
        animation.onComplete?.();
      };

      frameRef.current = uiClock.frame(tick);
    },
    [cancelFrame, reducedMotion]
  );

  useEffect(() => {
    animateTo(eyePoses[expression], reducedMotion ? 0 : eyeMorphDuration);
  }, [animateTo, expression, reducedMotion]);

  useEffect(() => {
    if (expression !== "neutral" || reducedMotion) {
      return;
    }
    let disposed = false;
    const scheduleBlink = () => {
      const delay = 2_800 + Math.random() * 1_800;
      // motion
      blinkTimerRef.current = uiClock.after(delay, () => {
        animateTo(eyePoses.blink, blinkCloseDuration, () => {
          animateTo(eyePoses.neutral, blinkOpenDuration, () => {
            if (!disposed) {
              scheduleBlink();
            }
          });
        });
      });
    };
    scheduleBlink();
    return () => {
      disposed = true;
      if (blinkTimerRef.current) {
        blinkTimerRef.current();
      }
    };
  }, [animateTo, expression, reducedMotion]);

  useEffect(
    () => () => {
      cancelFrame();
      if (blinkTimerRef.current) {
        blinkTimerRef.current();
      }
    },
    [cancelFrame]
  );

  return pose;
};

const usePointerGaze = (
  svgRef: RefObject<SVGSVGElement | null>,
  enabled: boolean,
  reducedMotion: boolean
) => {
  const [gaze, setGaze] = useState<Point>({ x: 0, y: 0 });
  // Each axis of the gaze follows its own spring, computed from the time
  // since it last started (../../motion): the same at any frame rate.
  const springsRef = useRef<{ x: Spring; y: Spring }>({
    x: createSpring(motionMascotElastic, 0, 0),
    y: createSpring(motionMascotElastic, 0, 0),
  });
  const frameRef = useRef<CancelUiTimer | null>(null);

  const stop = useCallback(() => {
    if (frameRef.current !== null) {
      frameRef.current();
      frameRef.current = null;
    }
  }, []);

  const lookAt = useCallback((target: Point) => {
    const now = uiClock.monotonic();
    retargetSpring(springsRef.current.x, now, target.x);
    retargetSpring(springsRef.current.y, now, target.y);
  }, []);

  const start = useCallback(() => {
    if (frameRef.current !== null) {
      return;
    }
    const tick = (now: number) => {
      const { x, y } = springsRef.current;
      const atX = springStateAt(x, now);
      const atY = springStateAt(y, now);
      if (
        springAtRest(atX, x.target, 0.01, 0.02) &&
        springAtRest(atY, y.target, 0.01, 0.02)
      ) {
        placeSpring(x, now, x.target);
        placeSpring(y, now, y.target);
        setGaze({ x: x.target, y: y.target });
        frameRef.current = null;
        return;
      }
      // An overshoot past the eye's reach holds at its edge.
      const gazeDistance = Math.hypot(atX.position, atY.position);
      const scale =
        gazeDistance > commaMascotMaxGazeDistance
          ? commaMascotMaxGazeDistance / gazeDistance
          : 1;
      setGaze({ x: atX.position * scale, y: atY.position * scale });
      frameRef.current = uiClock.frame(tick);
    };
    frameRef.current = uiClock.frame(tick);
  }, []);

  useEffect(() => {
    if (reducedMotion) {
      stop();
      const now = uiClock.monotonic();
      placeSpring(springsRef.current.x, now, 0);
      placeSpring(springsRef.current.y, now, 0);
      setGaze({ x: 0, y: 0 });
      return;
    }
    lookAt({ x: 0, y: 0 });
    start();
    if (!enabled) {
      return;
    }

    const handlePointerMove = (event: PointerEvent) => {
      if (event.pointerType !== "mouse" && event.pointerType !== "pen") {
        return;
      }
      const rect = svgRef.current?.getBoundingClientRect();
      if (!rect || rect.width === 0 || rect.height === 0) {
        return;
      }
      const deltaX = event.clientX - (rect.left + rect.width / 2);
      const deltaY = event.clientY - (rect.top + rect.height / 2);
      const distance = Math.hypot(deltaX, deltaY) || 1;
      const strength = Math.min(
        distance / (Math.max(rect.width, rect.height) * 1.5),
        1
      );
      lookAt({
        x: (deltaX / distance) * commaMascotMaxGazeDistance * strength,
        y: (deltaY / distance) * commaMascotMaxGazeDistance * strength,
      });
      start();
    };

    window.addEventListener("pointermove", handlePointerMove, { passive: true });
    return () => window.removeEventListener("pointermove", handlePointerMove);
  }, [enabled, lookAt, reducedMotion, start, stop, svgRef]);

  useEffect(() => stop, [stop]);
  return gaze;
};

export interface CommaMascotProps extends Omit<SVGAttributes<SVGSVGElement>, "color"> {
  color?: string;
  expression?: CommaMascotExpression;
  eyeColor?: string;
  followPointer?: boolean;
  interactive?: boolean;
  label?: string;
  showExpression?: boolean;
  size?: number | string;
}

export const CommaMascot = ({
  className,
  color,
  expression = "neutral",
  eyeColor,
  followPointer = false,
  interactive = true,
  label = "Comma mascot",
  onPointerDown,
  onPointerMove,
  onPointerUp,
  onPointerCancel,
  showExpression = true,
  size = 96,
  style,
  ...rest
}: CommaMascotProps) => {
  const svgRef = useRef<SVGSVGElement | null>(null);
  const meshRef = useRef(createSoftBodyMesh());
  const meshFrameRef = useRef<CancelUiTimer | null>(null);
  // When the mesh started moving and how many steps it has run since; null
  // while it rests.
  const meshClockRef = useRef<{ origin: number; steps: number } | null>(null);
  const [, setMeshRevision] = useState(0);
  const [dragging, setDragging] = useState(false);
  const reducedMotion = useSyncExternalStore(
    subscribeToReducedMotion,
    isReducedMotionEnabled,
    reducedMotionServerSnapshot
  );
  const eyes = useEyePose(expression, reducedMotion);
  const gaze = usePointerGaze(svgRef, followPointer && showExpression, reducedMotion);

  const stopMeshLoop = useCallback(() => {
    if (meshFrameRef.current !== null) {
      meshFrameRef.current();
      meshFrameRef.current = null;
    }
    meshClockRef.current = null;
  }, []);

  // Steps the mesh to `now`, from where it was stepped to: the steps a time
  // gets are the same whatever frames fell before it. Input steps it first,
  // so the drag changes from the time it happened.
  const stepMeshTo = useCallback((now: number) => {
    const clock = meshClockRef.current;
    if (clock === null) {
      meshClockRef.current = { origin: now, steps: 0 };
      return true;
    }
    // Counted from the origin, so rounding never moves a step between frames.
    const due = Math.floor((now - clock.origin) / softBodyStepMs + 1e-6);
    const steps = due - clock.steps;
    clock.steps = due;
    return stepSoftBodyMesh(meshRef.current, steps);
  }, []);

  const startMeshLoop = useCallback(() => {
    if (meshFrameRef.current !== null) {
      return;
    }
    const tick = (now: number) => {
      const moving = stepMeshTo(now);
      setMeshRevision((revision) => revision + 1);
      if (moving) {
        meshFrameRef.current = uiClock.frame(tick);
        return;
      }
      resetSoftBodyMesh(meshRef.current);
      setMeshRevision((revision) => revision + 1);
      meshFrameRef.current = null;
      meshClockRef.current = null;
    };
    meshFrameRef.current = uiClock.frame(tick);
  }, [stepMeshTo]);

  useEffect(() => {
    if (!reducedMotion) {
      return;
    }
    stopMeshLoop();
    resetSoftBodyMesh(meshRef.current);
    setDragging(false);
    setMeshRevision((revision) => revision + 1);
  }, [reducedMotion, stopMeshLoop]);

  useEffect(() => stopMeshLoop, [stopMeshLoop]);

  const eventPoint = useCallback((event: ReactPointerEvent<SVGSVGElement>) => {
    const svg = svgRef.current;
    if (!svg) {
      return null;
    }
    const rect = svg.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) {
      return null;
    }
    return {
      x: ((event.clientX - rect.left) / rect.width) * VIEWBOX_SIZE,
      y: ((event.clientY - rect.top) / rect.height) * VIEWBOX_SIZE,
    };
  }, []);

  const handlePointerDown = (event: ReactPointerEvent<SVGSVGElement>) => {
    onPointerDown?.(event);
    if (
      event.defaultPrevented ||
      !interactive ||
      reducedMotion ||
      (event.button !== 0 && event.pointerType === "mouse")
    ) {
      return;
    }
    const point = eventPoint(event);
    if (!point || !isMascotPoint(point)) {
      return;
    }
    event.currentTarget.setPointerCapture(event.pointerId);
    stepMeshTo(uiClock.monotonic());
    beginSoftBodyDrag(meshRef.current, point);
    setDragging(true);
    startMeshLoop();
  };

  const handlePointerMove = (event: ReactPointerEvent<SVGSVGElement>) => {
    onPointerMove?.(event);
    if (!meshRef.current.drag) {
      return;
    }
    const point = eventPoint(event);
    if (!point) {
      return;
    }
    stepMeshTo(uiClock.monotonic());
    moveSoftBodyDrag(meshRef.current, point);
    startMeshLoop();
  };

  const releasePointer = (event: ReactPointerEvent<SVGSVGElement>) => {
    if (!meshRef.current.drag) {
      return;
    }
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    stepMeshTo(uiClock.monotonic());
    endSoftBodyDrag(meshRef.current);
    setDragging(false);
    startMeshLoop();
  };

  const releaseMesh = useCallback(() => {
    if (!meshRef.current.drag) {
      return;
    }
    stepMeshTo(uiClock.monotonic());
    endSoftBodyDrag(meshRef.current);
    setDragging(false);
    startMeshLoop();
  }, [startMeshLoop, stepMeshTo]);

  useEffect(() => {
    if (!dragging) {
      return;
    }
    const handleGlobalRelease = () => releaseMesh();
    window.addEventListener("pointerup", handleGlobalRelease, true);
    window.addEventListener("pointercancel", handleGlobalRelease, true);
    window.addEventListener("blur", handleGlobalRelease);
    return () => {
      window.removeEventListener("pointerup", handleGlobalRelease, true);
      window.removeEventListener("pointercancel", handleGlobalRelease, true);
      window.removeEventListener("blur", handleGlobalRelease);
    };
  }, [dragging, releaseMesh]);

  const handlePointerUp = (event: ReactPointerEvent<SVGSVGElement>) => {
    onPointerUp?.(event);
    releasePointer(event);
  };

  const handlePointerCancel = (event: ReactPointerEvent<SVGSVGElement>) => {
    onPointerCancel?.(event);
    releasePointer(event);
  };

  const mesh = meshRef.current;
  const outerPath = closedCurvePath(mesh, commaMascotOuterPoints, OUTER_SHARP_INDICES);
  const corePath = closedCurvePath(mesh, commaMascotCorePoints, CORE_SHARP_INDICES);

  return (
    <svg
      {...rest}
      ref={svgRef}
      aria-label={label}
      className={cx("comma-mascot", className)}
      data-dragging={dragging ? "true" : "false"}
      data-expression={expression}
      data-follow-pointer={
        showExpression && followPointer && !reducedMotion ? "true" : "false"
      }
      data-interactive={interactive && !reducedMotion ? "true" : "false"}
      data-mesh={`${mesh.columns}x${mesh.rows}`}
      data-show-expression={showExpression ? "true" : "false"}
      height={size}
      onPointerCancel={handlePointerCancel}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onLostPointerCapture={releaseMesh}
      role="img"
      style={{ ...style, touchAction: "none" }}
      viewBox={`0 0 ${VIEWBOX_SIZE} ${VIEWBOX_SIZE}`}
      width={size}
    >
      <path
        data-part="outer"
        d={outerPath}
        fill={color ?? "var(--color-text-primary)"}
      />
      <path data-part="core" d={corePath} fill={color ?? "var(--color-text-primary)"} />
      <g className="comma-mascot__expression" aria-hidden={!showExpression}>
        <g
          className="comma-mascot__gaze"
          transform={`translate(${gaze.x.toFixed(3)} ${gaze.y.toFixed(3)})`}
        >
          {eyes.map((eye, index) => (
            <g
              key={index}
              className={`comma-mascot__eye-motion comma-mascot__eye-motion--${index + 1}`}
            >
              <path
                className="comma-mascot__eye"
                d={closedCurvePath(mesh, eye)}
                fill={eyeColor ?? "var(--color-bg-primary)"}
              />
            </g>
          ))}
        </g>
      </g>
    </svg>
  );
};

export const commaMascotExpressions = [
  "neutral",
  "happy",
  "squint",
  "squeezed",
  "surprised",
  "sleepy",
  "curious",
  "determined",
  "dizzy",
  "wink",
] as const satisfies readonly CommaMascotExpression[];
