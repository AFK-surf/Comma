import { cx, definedProps } from "../utils";

export type IndicatorSize = "sm" | "md" | "lg";
export type IndicatorColor = "gray" | "brand" | "success" | "warning" | "error";

const sizeClasses: Record<IndicatorSize, string> = {
  sm: "size-1.5",
  md: "size-2",
  lg: "size-2.5",
};

const colorClasses: Record<IndicatorColor, string> = {
  gray: "bg-fg-quaternary",
  brand: "bg-fg-brand-primary",
  success: "bg-fg-success-primary",
  warning: "bg-fg-warning-primary",
  error: "bg-fg-error-primary",
};

export interface IndicatorProps {
  size?: IndicatorSize;
  color?: IndicatorColor;
  pulse?: boolean;
  className?: string;
  label?: string;
}

export const Indicator = ({
  size = "md",
  color = "gray",
  pulse = false,
  className,
  label,
}: IndicatorProps) => (
  <span
    className={cx("relative inline-flex", className)}
    {...definedProps({
      role: label ? "img" : undefined,
      "aria-label": label,
    })}
  >
    {pulse && (
      <span
        className={cx(
          "absolute inline-flex animate-ping rounded-full opacity-75",
          sizeClasses[size],
          colorClasses[color]
        )}
        aria-hidden
      />
    )}
    <span
      className={cx(
        "relative inline-flex rounded-full",
        sizeClasses[size],
        colorClasses[color]
      )}
    />
  </span>
);
