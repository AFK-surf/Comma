import { motionDuration } from "../../tokens/motion";
import type { Point } from "./softBodyMesh";

export type CommaMascotExpression =
  | "neutral"
  | "happy"
  | "squint"
  | "squeezed"
  | "surprised"
  | "sleepy"
  | "curious"
  | "determined"
  | "dizzy"
  | "wink";

export type EyeShape = readonly Point[];
export type EyePose = readonly [EyeShape, EyeShape];

export const eyeMorphDuration = motionDuration.iconSwap;
export const blinkCloseDuration = motionDuration.feedbackIn;
export const blinkOpenDuration = motionDuration.feedbackOut;

const EYE_POINT_COUNT = 12;

const ellipse = (
  centerX: number,
  centerY: number,
  radiusX: number,
  radiusY: number
): EyeShape =>
  Array.from({ length: EYE_POINT_COUNT }, (_, index) => {
    const angle = (Math.PI * 2 * index) / EYE_POINT_COUNT - Math.PI / 2;
    return {
      x: centerX + Math.cos(angle) * radiusX,
      y: centerY + Math.sin(angle) * radiusY,
    };
  });

const quadraticPoint = (start: Point, control: Point, end: Point, t: number) => {
  const inverse = 1 - t;
  return {
    x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
    y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y,
  };
};

/** Builds a closed, constant-topology ribbon around a quadratic eye curve. */
const ribbon = (
  start: Point,
  control: Point,
  end: Point,
  thickness: number
): EyeShape => {
  const half = thickness / 2;
  const sideA: Point[] = [];
  const sideB: Point[] = [];
  const samples = EYE_POINT_COUNT / 2;

  for (let index = 0; index < samples; index += 1) {
    const t = index / (samples - 1);
    const point = quadraticPoint(start, control, end, t);
    const before = quadraticPoint(start, control, end, Math.max(0, t - 0.01));
    const after = quadraticPoint(start, control, end, Math.min(1, t + 0.01));
    const tangentX = after.x - before.x;
    const tangentY = after.y - before.y;
    const length = Math.hypot(tangentX, tangentY) || 1;
    const normalX = -tangentY / length;
    const normalY = tangentX / length;
    sideA.push({ x: point.x + normalX * half, y: point.y + normalY * half });
    sideB.push({ x: point.x - normalX * half, y: point.y - normalY * half });
  }

  return [...sideA, ...sideB.toReversed()];
};

const cross = (
  centerX: number,
  centerY: number,
  radius: number,
  thickness: number
): EyeShape => [
  { x: centerX - radius, y: centerY - radius + thickness },
  { x: centerX - radius + thickness, y: centerY - radius },
  { x: centerX, y: centerY - thickness },
  { x: centerX + radius - thickness, y: centerY - radius },
  { x: centerX + radius, y: centerY - radius + thickness },
  { x: centerX + thickness, y: centerY },
  { x: centerX + radius, y: centerY + radius - thickness },
  { x: centerX + radius - thickness, y: centerY + radius },
  { x: centerX, y: centerY + thickness },
  { x: centerX - radius + thickness, y: centerY + radius },
  { x: centerX - radius, y: centerY + radius - thickness },
  { x: centerX - thickness, y: centerY },
];

export const eyePoses: Record<CommaMascotExpression | "blink", EyePose> = {
  neutral: [ellipse(91, 91, 6.5, 12), ellipse(122, 91, 6.5, 12)],
  happy: [
    ribbon({ x: 81, y: 98 }, { x: 91, y: 84 }, { x: 101, y: 98 }, 6),
    ribbon({ x: 112, y: 98 }, { x: 122, y: 84 }, { x: 132, y: 98 }, 6),
  ],
  squint: [
    ribbon({ x: 81, y: 94 }, { x: 91, y: 90 }, { x: 101, y: 94 }, 4.5),
    ribbon({ x: 112, y: 94 }, { x: 122, y: 90 }, { x: 132, y: 94 }, 4.5),
  ],
  squeezed: [
    ribbon({ x: 82, y: 85 }, { x: 91, y: 92 }, { x: 100, y: 100 }, 6),
    ribbon({ x: 113, y: 100 }, { x: 122, y: 92 }, { x: 131, y: 85 }, 6),
  ],
  surprised: [ellipse(91, 91, 7, 16), ellipse(122, 91, 7, 16)],
  sleepy: [
    ribbon({ x: 81, y: 92 }, { x: 91, y: 101 }, { x: 101, y: 92 }, 5),
    ribbon({ x: 112, y: 92 }, { x: 122, y: 101 }, { x: 132, y: 92 }, 5),
  ],
  curious: [ellipse(91, 93, 5.5, 9.5), ellipse(122, 89, 8, 14)],
  determined: [
    ribbon({ x: 81, y: 85 }, { x: 91, y: 88 }, { x: 101, y: 95 }, 6),
    ribbon({ x: 112, y: 95 }, { x: 122, y: 88 }, { x: 132, y: 85 }, 6),
  ],
  dizzy: [cross(91, 91, 9, 3.5), cross(122, 91, 9, 3.5)],
  wink: [
    ribbon({ x: 81, y: 96 }, { x: 91, y: 83 }, { x: 101, y: 96 }, 6),
    ellipse(122, 91, 6.5, 12),
  ],
  blink: [
    ribbon({ x: 82, y: 92 }, { x: 91, y: 94 }, { x: 100, y: 92 }, 3.5),
    ribbon({ x: 113, y: 92 }, { x: 122, y: 94 }, { x: 131, y: 92 }, 3.5),
  ],
};

export const interpolateEyePose = (from: EyePose, to: EyePose, progress: number) =>
  from.map((eye, eyeIndex) =>
    eye.map((point, pointIndex) => {
      const target = to[eyeIndex]![pointIndex]!;
      return {
        x: point.x + (target.x - point.x) * progress,
        y: point.y + (target.y - point.y) * progress,
      };
    })
  ) as unknown as EyePose;

const cubicCoordinate = (t: number, first: number, second: number) => {
  const inverse = 1 - t;
  return 3 * inverse * inverse * t * first + 3 * inverse * t * t * second + t ** 3;
};

const cubicDerivative = (t: number, first: number, second: number) =>
  3 * (1 - t) ** 2 * first +
  6 * (1 - t) * t * (second - first) +
  3 * t ** 2 * (1 - second);

/** Evaluates Comma's generatedMediaSwap cubic-bezier(0.77, 0, 0.175, 1). */
export const eyeMorphEasing = (progress: number) => {
  const clamped = Math.min(Math.max(progress, 0), 1);
  let parameter = clamped;
  for (let iteration = 0; iteration < 6; iteration += 1) {
    const slope = cubicDerivative(parameter, 0.77, 0.175);
    if (Math.abs(slope) < 1e-6) {
      break;
    }
    parameter -= (cubicCoordinate(parameter, 0.77, 0.175) - clamped) / slope;
    parameter = Math.min(Math.max(parameter, 0), 1);
  }
  return cubicCoordinate(parameter, 0, 1);
};
