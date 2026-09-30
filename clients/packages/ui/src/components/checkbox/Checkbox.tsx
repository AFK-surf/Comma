import type { InputHTMLAttributes, ReactNode } from "react";
import { Checkbox as AriaCheckbox } from "react-aria-components";
import { cx, definedProps } from "../utils";
import { CheckboxBase } from "./CheckboxBase";

export type CheckboxSize = "sm" | "md";

export interface CheckboxControlState {
  isFocusVisible: boolean;
  isHovered: boolean;
  isPressed: boolean;
  isSelected: boolean;
}

export interface CheckboxProps extends Omit<
  InputHTMLAttributes<HTMLInputElement>,
  "size" | "value" | "className"
> {
  size?: CheckboxSize;
  label?: ReactNode;
  hint?: string;
  indeterminate?: boolean;
  className?: string;
  controlClassName?: string | ((state: CheckboxControlState) => string | undefined);
  value?: string;
}

const labelStyles = {
  sm: { root: "gap-2", text: "text-sm" },
  md: { root: "gap-3", text: "text-sm" },
} as const;

export const Checkbox = ({
  size = "md",
  label,
  hint,
  indeterminate,
  className,
  controlClassName,
  disabled,
  checked,
  defaultChecked,
  onChange,
  name,
  value,
  id,
  "aria-label": ariaLabel,
}: CheckboxProps) => {
  const hasHint = Boolean(hint);

  return (
    <AriaCheckbox
      {...definedProps({
        id,
        name,
        value,
        isDisabled: disabled,
        isSelected: checked,
        defaultSelected: defaultChecked,
        isIndeterminate: indeterminate,
        "aria-label": ariaLabel,
      })}
      onChange={(selected) =>
        onChange?.({
          target: { checked: selected },
        } as React.ChangeEvent<HTMLInputElement>)
      }
      className={cx(
        "relative flex",
        hasHint ? "items-start" : "items-center",
        disabled && "cursor-not-allowed",
        labelStyles[size].root,
        className
      )}
    >
      {({
        isSelected,
        isIndeterminate,
        isDisabled,
        isFocusVisible,
        isHovered,
        isPressed,
      }) => {
        const resolvedControlClassName =
          typeof controlClassName === "function"
            ? controlClassName({
                isFocusVisible,
                isHovered,
                isPressed,
                isSelected,
              })
            : controlClassName;

        return (
          <>
            <CheckboxBase
              size={size}
              isSelected={isSelected}
              isIndeterminate={isIndeterminate}
              isDisabled={isDisabled}
              isFocusVisible={isFocusVisible}
              {...definedProps({
                className: cx(hasHint && "mt-0.5", resolvedControlClassName),
              })}
            />
            {(label || hint) && (
              <div className="inline-flex min-w-0 flex-1 flex-col gap-0.5">
                {label && (
                  <p
                    className={cx(
                      "select-none font-medium text-secondary",
                      labelStyles[size].text
                    )}
                  >
                    {label}
                  </p>
                )}
                {hint && (
                  <span className={cx("text-tertiary", labelStyles[size].text)}>
                    {hint}
                  </span>
                )}
              </div>
            )}
          </>
        );
      }}
    </AriaCheckbox>
  );
};
