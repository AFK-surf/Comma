import type { ReactNode } from "react";
import type { ButtonProps as AriaButtonProps } from "react-aria-components";
import { Button as AriaButton } from "react-aria-components";
import { PlaceholderIcon } from "../icons";
import { cx, definedProps } from "../utils";
import {
  baseClasses,
  dotSizeClasses,
  hierarchyClasses,
  iconOnlySizeClasses,
  iconSlotClasses,
  linkSizeClasses,
  sizeClasses,
} from "./styles";
import type { ButtonHierarchy, ButtonSize } from "./types";

export interface ButtonProps extends Omit<AriaButtonProps, "className" | "children"> {
  hierarchy?: ButtonHierarchy;
  size?: ButtonSize;
  iconLeading?: ReactNode;
  iconTrailing?: ReactNode;
  /**
   * Trailing content rendered at its own size, outside the square icon slot —
   * for adornments wider than a glyph, such as the dialog shortcut keycaps.
   */
  adornmentTrailing?: ReactNode;
  iconOnly?: boolean;
  dotLeading?: boolean;
  className?: string;
  children?: ReactNode;
  disabled?: boolean;
}

const isLink = (hierarchy: ButtonHierarchy) =>
  hierarchy === "link-color" || hierarchy === "link-gray";

export const Button = ({
  hierarchy = "primary",
  size = "md",
  iconLeading,
  iconTrailing,
  adornmentTrailing,
  iconOnly = false,
  dotLeading = false,
  type = "button",
  className,
  children,
  isDisabled,
  disabled,
  ...rest
}: ButtonProps) => {
  const link = isLink(hierarchy);
  const sizeClass = iconOnly
    ? iconOnlySizeClasses[size]
    : link
      ? linkSizeClasses[size]
      : sizeClasses[size];
  const iconSlotClass = iconSlotClasses[size];

  const renderIconSlot = (icon: ReactNode) => (
    <span className={iconSlotClass}>{icon}</span>
  );

  const leading = dotLeading ? (
    <span
      aria-hidden
      className={cx(
        "shrink-0 rounded-full bg-fg-success-primary",
        dotSizeClasses[size]
      )}
    />
  ) : iconLeading ? (
    renderIconSlot(iconLeading)
  ) : iconOnly ? (
    renderIconSlot(<PlaceholderIcon />)
  ) : null;

  return (
    <AriaButton
      type={type}
      {...definedProps({ isDisabled: isDisabled ?? disabled })}
      className={cx(
        baseClasses,
        hierarchyClasses[hierarchy],
        sizeClass,
        iconOnly && "gap-0",
        className
      )}
      {...rest}
    >
      {iconOnly ? (
        <span className="inline-flex shrink-0 items-center justify-center leading-none">
          {leading}
        </span>
      ) : (
        leading
      )}
      {!iconOnly && children && <span className="px-0.5">{children}</span>}
      {!iconOnly && iconTrailing && renderIconSlot(iconTrailing)}
      {!iconOnly && adornmentTrailing}
    </AriaButton>
  );
};
