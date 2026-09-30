import type { ChangeEvent, InputHTMLAttributes } from "react";
import { Switch as AriaSwitch } from "react-aria-components";
import { cx, definedProps } from "../utils";
import { ToggleBase } from "./ToggleBase";

export type ToggleSize = "sm" | "md";

export interface ToggleProps extends Omit<
  InputHTMLAttributes<HTMLInputElement>,
  "size" | "value" | "className"
> {
  size?: ToggleSize;
  label?: string;
  hint?: string;
  slim?: boolean;
  className?: string;
  value?: string;
}

const labelStyles = {
  sm: { root: "gap-2", text: "text-sm" },
  md: { root: "gap-3", text: "text-sm" },
} as const;

type ToggleVisualProps = {
  hint: string | undefined;
  isDisabled: boolean;
  isFocusVisible: boolean;
  isHovered: boolean;
  isSelected: boolean;
  label: string | undefined;
  size: ToggleSize;
  slim: boolean;
};

/**
 * No motion state to track: the knob is placed by its two edges and the
 * trailing edge lags, so a transition interpolates from wherever the knob
 * currently is — including mid-hover and mid-flight.
 */
const ToggleVisual = ({
  hint,
  isDisabled,
  isFocusVisible,
  isHovered,
  isSelected,
  label,
  size,
  slim,
}: ToggleVisualProps) => (
  <>
    <ToggleBase
      size={size}
      isHovered={isHovered}
      isDisabled={isDisabled}
      isFocusVisible={isFocusVisible}
      isSelected={isSelected}
      slim={slim}
      {...(slim ? { className: "mt-0.5" } : {})}
    />
    {(label || hint) && (
      <div className="flex flex-col gap-0.5">
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
          <span className={cx("text-tertiary", labelStyles[size].text)}>{hint}</span>
        )}
      </div>
    )}
  </>
);

export const Toggle = ({
  size = "md",
  label,
  hint,
  slim,
  className,
  disabled,
  checked,
  defaultChecked,
  onChange,
  name,
  value,
  id,
  "aria-label": ariaLabel,
}: ToggleProps) => {
  return (
    <AriaSwitch
      {...definedProps({
        "aria-label": ariaLabel,
        id,
        name,
        value,
        isDisabled: disabled,
        isSelected: checked,
        defaultSelected: defaultChecked,
      })}
      onChange={(selected) => {
        onChange?.({
          target: { checked: selected },
        } as ChangeEvent<HTMLInputElement>);
      }}
      className={cx(
        "relative flex w-max items-start",
        disabled && "cursor-not-allowed",
        labelStyles[size].root,
        className
      )}
    >
      {({ isSelected, isDisabled, isFocusVisible, isHovered }) => (
        <ToggleVisual
          hint={hint}
          isDisabled={isDisabled}
          isFocusVisible={isFocusVisible}
          isHovered={isHovered}
          isSelected={isSelected}
          label={label}
          size={size}
          slim={Boolean(slim)}
        />
      )}
    </AriaSwitch>
  );
};
