import { Button, Tooltip, cx, type ButtonProps } from "@comma/ui";
import type { CSSProperties, ReactNode } from "react";
import { AppIcon, type AppIconName } from "./icons";

const shellIconButtonStyle = {
  "--comma-button-hover-bg": "var(--color-sidebar-bg-item)",
  "--comma-button-hover-fg": "var(--color-sidebar-icon-primary)",
} as CSSProperties;

type ShellIconButtonControlProps = Omit<
  ButtonProps,
  "children" | "className" | "hierarchy" | "iconLeading" | "iconOnly" | "size" | "style"
> & {
  className?: string;
  icon: ReactNode;
};

/** The shell icon-button appearance without Tooltip or other trigger wrappers. */
export function ShellIconButtonControl({
  className,
  disabled,
  icon,
  isDisabled,
  ...props
}: ShellIconButtonControlProps) {
  const resolvedDisabled = isDisabled ?? disabled ?? false;

  return (
    <Button
      className={cx(
        "comma-icon-button size-7 border-0 bg-transparent p-xs text-sidebar-icon-primary transition-colors duration-[50ms] focus-visible:shadow-focus-gray disabled:cursor-default disabled:text-sidebar-icon-disabled disabled:opacity-80",
        className
      )}
      hierarchy="tertiary-gray"
      iconLeading={icon}
      iconOnly
      size="sm"
      {...(disabled === undefined ? {} : { disabled })}
      {...(isDisabled === undefined ? {} : { isDisabled })}
      {...(!resolvedDisabled ? { style: shellIconButtonStyle } : {})}
      {...props}
    />
  );
}

export function ShellIconButton({
  className,
  controls,
  disabled = false,
  expanded,
  icon,
  iconClassName,
  label,
  onBlur,
  onClick,
  onFocus,
  onMouseEnter,
  onMouseLeave,
  onPointerEnter,
  onPointerLeave,
  shortcut,
  testId,
  variant = "plain",
}: {
  className?: string;
  controls?: string;
  disabled?: boolean;
  expanded?: boolean;
  icon: AppIconName;
  iconClassName?: string;
  label: string;
  onBlur?: () => void;
  onClick?: () => void;
  onFocus?: () => void;
  onMouseEnter?: () => void;
  onMouseLeave?: () => void;
  onPointerEnter?: () => void;
  onPointerLeave?: () => void;
  shortcut?: string | readonly string[];
  /** Test hook, rendered as `data-testid` on the control itself. */
  testId?: string;
  variant?: "muted" | "plain";
}) {
  const eventProps = {
    ...(onBlur ? { onBlur } : {}),
    ...(onClick ? { onPress: onClick } : {}),
    ...(onFocus ? { onFocus } : {}),
    ...(onMouseEnter ? { onMouseEnter } : {}),
    ...(onMouseLeave ? { onMouseLeave } : {}),
    ...(onPointerEnter ? { onPointerEnter } : {}),
    ...(onPointerLeave ? { onPointerLeave } : {}),
  };
  const expandedProps =
    typeof expanded === "boolean" ? { "aria-expanded": expanded } : {};

  return (
    <Tooltip content={label} placement="bottom" {...(shortcut ? { shortcut } : {})}>
      <ShellIconButtonControl
        {...(controls ? { "aria-controls": controls } : {})}
        {...(testId ? { "data-testid": testId } : {})}
        aria-label={label}
        className={cx(
          "shrink-0",
          variant === "muted" && "comma-icon-button-muted bg-disabled",
          className
        )}
        disabled={disabled}
        icon={<AppIcon name={icon} className={cx("comma-input-icon", iconClassName)} />}
        {...eventProps}
        {...expandedProps}
      />
    </Tooltip>
  );
}
