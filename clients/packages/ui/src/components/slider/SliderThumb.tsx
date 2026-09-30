/* oxlint-disable jsx-a11y/prefer-tag-over-role */
import type { KeyboardEvent, PointerEvent } from "react";
import { cx } from "../utils";
import { percentToThumbLeft } from "./slider-geometry";
import type { SliderLabelPosition } from "./styles";
import { bottomLabelClass, thumbClass, thumbHandleClass, tooltipClass } from "./styles";

type SliderThumbProps = {
  position: number;
  value: number;
  min: number;
  max: number;
  label: string;
  labelPosition: SliderLabelPosition;
  ariaLabel: string;
  disabled?: boolean;
  onKeyDown: (event: KeyboardEvent<HTMLButtonElement>) => void;
  onPointerDown: (event: PointerEvent<HTMLButtonElement>) => void;
};

export const SliderThumb = ({
  position,
  value,
  min,
  max,
  label,
  labelPosition,
  ariaLabel,
  disabled = false,
  onKeyDown,
  onPointerDown,
}: SliderThumbProps) => (
  <button
    type="button"
    role="slider"
    aria-label={ariaLabel}
    aria-valuemin={min}
    aria-valuemax={max}
    aria-valuenow={value}
    disabled={disabled}
    className={cx(thumbClass, thumbHandleClass)}
    style={{ left: percentToThumbLeft(position) }}
    onKeyDown={onKeyDown}
    onPointerDown={onPointerDown}
  >
    {labelPosition === "tooltip" && <span className={tooltipClass}>{label}</span>}
    {labelPosition === "bottom" && <span className={bottomLabelClass}>{label}</span>}
  </button>
);
