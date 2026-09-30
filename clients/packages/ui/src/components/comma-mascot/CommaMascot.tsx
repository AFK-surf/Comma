/* oxlint-disable jsx-a11y/prefer-tag-over-role -- The mascot is an interactive vector graphic; replacing it with img would remove its mesh interaction. */
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
  const frameRef = useRef<number | null>(null);
  const blinkTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [pose, setPose] = useState<EyePose>(eyePoses[expression]);

  const cancelFrame = useCallback(() => {
    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current);
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
        startedAt: performance.now(),
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
          frameRef.current = window.requestAnimationFrame(tick);
          return;
        }
        animationRef.current = null;
        frameRef.current = null;
        animation.onComplete?.();
      };

      frameRef.current = window.requestAnimationFrame(tick);
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
      blinkTimerRef.current = setTimeout(() => {
        animateTo(eyePoses.blink, blinkCloseDuration, () => {
          animateTo(eyePoses.neutral, blinkOpenDuration, () => {
            if (!disposed) {
              scheduleBlink();
            }
          });
        });
      }, delay);
    };
    scheduleBlink();
    return () => {
      disposed = true;
      if (blinkTimerRef.current) {
        clearTimeout(blinkTimerRef.current);
      }
    };
  }, [animateTo, expression, reducedMotion]);

  useEffect(
    () => () => {
      cancelFrame();
      if (blinkTimerRef.current) {
        clearTimeout(blinkTimerRef.current);
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
  const currentRef = useRef<Point>({ x: 0, y: 0 });
  const targetRef = useRef<Point>({ x: 0, y: 0 });
  const velocityRef = useRef<Point>({ x: 0, y: 0 });
  const frameRef = useRef<number | null>(null);
  const previousTimeRef = useRef<number | null>(null);

  const stop = useCallback(() => {
    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current);
      frameRef.current = null;
    }
    previousTimeRef.current = null;
  }, []);

  const start = useCallback(() => {
    if (frameRef.current !== null) {
      return;
    }
    const tick = (now: number) => {
      const previous = previousTimeRef.current ?? now - 1000 / 60;
      const dt = Math.min((now - previous) / 1000, 1 / 30);
      previousTimeRef.current = now;
      const current = currentRef.current;
      const target = targetRef.current;
      const velocity = velocityRef.current;
      const { damping, mass, stiffness } = motionMascotElastic;

      velocity.x +=
        (((target.x - current.x) * stiffness - velocity.x * damping) / mass) * dt;
      velocity.y +=
        (((target.y - current.y) * stiffness - velocity.y * damping) / mass) * dt;
      current.x += velocity.x * dt;
      current.y += velocity.y * dt;
      const gazeDistance = Math.hypot(current.x, current.y);
      if (gazeDistance > commaMascotMaxGazeDistance) {
        const scale = commaMascotMaxGazeDistance / gazeDistance;
        current.x *= scale;
        current.y *= scale;
        velocity.x = 0;
        velocity.y = 0;
      }
      setGaze({ ...current });

      const displacement = Math.hypot(target.x - current.x, target.y - current.y);
      const speed = Math.hypot(velocity.x, velocity.y);
      if (displacement > 0.01 || speed > 0.02) {
        frameRef.current = window.requestAnimationFrame(tick);
        return;
      }
      currentRef.current = { ...target };
      velocityRef.current = { x: 0, y: 0 };
      setGaze({ ...target });
      frameRef.current = null;
      previousTimeRef.current = null;
    };
    frameRef.current = window.requestAnimationFrame(tick);
  }, []);

  useEffect(() => {
    targetRef.current = { x: 0, y: 0 };
    if (reducedMotion) {
      stop();
      currentRef.current = { x: 0, y: 0 };
      velocityRef.current = { x: 0, y: 0 };
      setGaze({ x: 0, y: 0 });
      return;
    }
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
      targetRef.current = {
        x: (deltaX / distance) * commaMascotMaxGazeDistance * strength,
        y: (deltaY / distance) * commaMascotMaxGazeDistance * strength,
      };
      start();
    };

    window.addEventListener("pointermove", handlePointerMove, { passive: true });
    return () => window.removeEventListener("pointermove", handlePointerMove);
  }, [enabled, reducedMotion, start, stop, svgRef]);

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
  const meshFrameRef = useRef<number | null>(null);
  const previousFrameTimeRef = useRef<number | null>(null);
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
      window.cancelAnimationFrame(meshFrameRef.current);
      meshFrameRef.current = null;
    }
    previousFrameTimeRef.current = null;
  }, []);

  const startMeshLoop = useCallback(() => {
    if (meshFrameRef.current !== null) {
      return;
    }
    const tick = (now: number) => {
      const previous = previousFrameTimeRef.current ?? now - 1000 / 60;
      previousFrameTimeRef.current = now;
      const moving = stepSoftBodyMesh(meshRef.current, (now - previous) / 1000);
      setMeshRevision((revision) => revision + 1);
      if (moving) {
        meshFrameRef.current = window.requestAnimationFrame(tick);
        return;
      }
      resetSoftBodyMesh(meshRef.current);
      setMeshRevision((revision) => revision + 1);
      meshFrameRef.current = null;
      previousFrameTimeRef.current = null;
    };
    meshFrameRef.current = window.requestAnimationFrame(tick);
  }, []);

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
    endSoftBodyDrag(meshRef.current);
    setDragging(false);
    startMeshLoop();
  };

  const releaseMesh = useCallback(() => {
    if (!meshRef.current.drag) {
      return;
    }
    endSoftBodyDrag(meshRef.current);
    setDragging(false);
    startMeshLoop();
  }, [startMeshLoop]);

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
