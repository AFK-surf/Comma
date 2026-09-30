import { useId } from "react";
import type { ComponentProps, CSSProperties } from "react";

const logoPath =
  "M365.205 0C566.902 0 730.411 163.508 730.411 365.205C730.411 392.364 727.389 418.813 721.737 444.273C719.941 452.362 708.534 452.973 704.742 445.605C688.107 413.29 662.342 385.203 628.529 365.681C534.639 311.479 414.537 343.676 360.331 437.565C306.144 531.45 338.338 651.516 432.215 705.722C433.08 706.222 433.949 706.715 434.82 707.198C442.064 711.222 441.112 722.559 432.968 724.093C411.011 728.229 388.362 730.411 365.205 730.411C163.51 730.411 0.00300803 566.9 0 365.205C0.000195125 163.508 163.508 0.000175857 365.205 0Z";

const maskPath =
  "M365 0A365 365 0 0 1 730 365V395A335 335 0 0 1 395 730H365A365 365 0 0 1 0 365A365 365 0 0 1 365 0Z";

const commaPath =
  "M429.061 468.826C465.24 406.162 545.367 384.693 608.03 420.871C668.125 455.568 690.333 530.683 660.141 592.052C660.216 592.125 660.291 592.197 660.366 592.27C659.322 594.203 658.133 596.254 656.801 598.406C656.532 598.885 656.261 599.364 655.986 599.84C649.213 611.571 640.898 621.858 631.448 630.594C600.921 662.613 550.308 698.191 480.175 708.083C477.447 708.468 475.903 705.159 477.946 703.31C490.729 691.748 505.726 678.045 520.57 663.529C505.64 660.994 490.898 655.812 477.015 647.796C414.351 611.617 392.882 531.489 429.061 468.826Z";

const easingCurves = {
  easeInOut: "cubic-bezier(0.77, 0, 0.175, 1)",
  easeOut: "cubic-bezier(0.23, 1, 0.32, 1)",
  linear: "linear",
} as const;

type CommaLogoEasing = keyof typeof easingCurves;

export type CommaLogoAnimationProps = Omit<ComponentProps<"svg">, "children"> & {
  easing?: CommaLogoEasing;
  /** Finite hold duration >= 0. Invalid numeric inputs throw RangeError. */
  intervalSeconds?: number;
  /** Finite percentage in [0, 100). */
  nestedDelayPercent?: number;
  paused?: boolean;
  /** Finite cycle position in [0, 1]. */
  progress?: number;
  size?: number;
  /** Finite zoom duration > 0; total cycle must also be finite. */
  zoomSeconds?: number;
};

export const CommaLogoAnimation = ({
  easing = "easeInOut",
  intervalSeconds = 1.4,
  nestedDelayPercent = 1,
  paused = false,
  progress = 0,
  size = 32,
  zoomSeconds = 2,
  className,
  style,
  ...svgProps
}: CommaLogoAnimationProps) => {
  const animationId = useId().replaceAll(":", "");
  const cycleSeconds = zoomSeconds + intervalSeconds;
  if (
    !Number.isFinite(zoomSeconds) ||
    zoomSeconds <= 0 ||
    !Number.isFinite(intervalSeconds) ||
    intervalSeconds < 0 ||
    !Number.isFinite(cycleSeconds) ||
    !Number.isFinite(progress) ||
    progress < 0 ||
    progress > 1 ||
    !Number.isFinite(nestedDelayPercent) ||
    nestedDelayPercent < 0 ||
    nestedDelayPercent >= 100
  ) {
    throw new RangeError(
      "CommaLogoAnimation requires zoomSeconds > 0, intervalSeconds >= 0, progress in [0, 1], nestedDelayPercent in [0, 100), and finite timing values."
    );
  }
  const motionEnd = (zoomSeconds / cycleSeconds) * 100;
  const nestedStart = motionEnd * (nestedDelayPercent / 100);
  const curve = easingCurves[easing] ?? easingCurves.easeInOut;
  const zoomAnimation = `comma-logo-zoom-${animationId}`;
  const nestedAnimation = `comma-logo-nested-${animationId}`;
  const boundaryId = `comma-logo-boundary-${animationId}`;

  return (
    <svg
      aria-label="Animated Comma logo"
      width={size}
      height={size}
      {...svgProps}
      className={["comma-logo-animation", className].filter(Boolean).join(" ")}
      data-slot="comma-logo-animation"
      data-paused={paused}
      style={
        {
          "--comma-logo-cycle": `${cycleSeconds}s`,
          "--comma-logo-delay": `${-progress * cycleSeconds}s`,
          "--comma-logo-nested-animation": nestedAnimation,
          "--comma-logo-zoom-animation": zoomAnimation,
          ...style,
        } as CSSProperties
      }
      viewBox="0 0 730 730"
      xmlns="http://www.w3.org/2000/svg"
    >
      <style>{`
      @keyframes ${zoomAnimation} {
        0% {
          animation-timing-function: ${curve};
          transform: matrix(1, 0, 0, 1, 0, 0);
        }
        ${motionEnd}% {
          transform: matrix(2.7756653992, 0, 0, 2.7756653992, -1140.7984790875, -1118.5931558935);
        }
        100% {
          transform: matrix(2.7756653992, 0, 0, 2.7756653992, -1140.7984790875, -1118.5931558935);
        }
      }

      @keyframes ${nestedAnimation} {
        0% {
          transform: scale(0);
        }
        ${nestedStart}% {
          animation-timing-function: ${curve};
          transform: scale(0);
        }
        ${motionEnd}% {
          transform: scale(1);
        }
        100% {
          transform: scale(1);
        }
      }
    `}</style>
      <defs>
        <clipPath id={boundaryId}>
          <path d={maskPath} />
        </clipPath>
      </defs>

      <g clipPath={`url(#${boundaryId})`}>
        <g className="comma-logo-animation__scene">
          <path className="comma-logo-animation__outer" d={logoPath} />
          <path className="comma-logo-animation__comma" d={commaPath} />

          <g className="comma-logo-animation__nested-comma">
            <g transform="translate(606.44863 595.56644) scale(0.3602739726) translate(-542.5 -534.5)">
              <circle
                className="comma-logo-animation__nested-aperture"
                cx="530.35544005"
                cy="535.69550225"
                r="196.33236187"
              />
              <path className="comma-logo-animation__nested-comma-path" d={commaPath} />
            </g>
          </g>
        </g>
      </g>
    </svg>
  );
};
