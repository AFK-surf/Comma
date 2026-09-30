import type { HTMLAttributes, ReactNode } from "react";
import { cx } from "../utils";
import { badgeDotColorClasses, sizeClasses, typeClasses } from "./styles";
import type { BadgeColor, BadgeSize, BadgeType } from "./styles";

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  color?: BadgeColor;
  size?: BadgeSize;
  type?: BadgeType;
  dot?: boolean;
  children?: ReactNode;
}

export const Badge = ({
  color = "gray",
  size = "sm",
  type = "pill-color",
  dot = false,
  className,
  children,
  ...rest
}: BadgeProps) => (
  <span
    className={cx(
      "inline-flex items-center gap-1 font-medium",
      typeClasses[type](color),
      sizeClasses[size],
      className
    )}
    {...rest}
  >
    {dot && (
      <span
        aria-hidden
        className={cx("size-1.5 shrink-0 rounded-full", badgeDotColorClasses[color])}
      />
    )}
    {children ?? "Label"}
  </span>
);

export type { BadgeColor, BadgeSize, BadgeType };
