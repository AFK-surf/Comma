import { CheckLargeIcon, MinusIcon } from "../icons";
import { cx } from "../utils";

export type CheckboxBaseProps = {
  size?: "sm" | "md";
  className?: string;
  isFocusVisible?: boolean;
  isSelected?: boolean;
  isDisabled?: boolean;
  isIndeterminate?: boolean;
};

/**
 * Comma checkbox as the product draws it (Comma App 1371:19264 default,
 * 1371:19133 checked, 1371:20658 indeterminate; disabled from the design
 * system's 1097:63719/63709/1224:6865): a 16px box on a panel fill with the
 * darker menu border and the xs shadow, filled brand-solid when it carries a
 * glyph, and the glyph itself inset 12.5% so it reads inside the box rather
 * than over its edges. One look everywhere — list rows, menus, forms — so the
 * same control never changes colour between surfaces.
 */
// The design insets the glyph 2px from a 16px box. An absolute inset resolves
// against the padding box, which the 1px border has already taken one pixel
// out of, so one more pixel lands the glyph on the design's 12px frame.
const iconInsetClasses = {
  sm: "inset-px",
  md: "inset-[15%]",
} as const;

// The design draws the tick 8px wide with a 1.67px stroke inside the 12px
// frame (a 12-unit asset at stroke 1.6666). The library's full-size checkmark
// spans 14 of its 24 units, so it lands at 7px here; its 2-unit stroke would
// paint 1px, so the glyph asks the global stroke hook for 3.33 units instead.
const iconClasses = "size-full [--comma-icon-stroke-width:3.33] [&_svg]:size-full";

export const CheckboxBase = ({
  className,
  isSelected,
  isDisabled,
  isIndeterminate,
  size = "sm",
  isFocusVisible = false,
}: CheckboxBaseProps) => (
  <div
    className={cx(
      "comma-icon-slot relative flex size-4 shrink-0 cursor-pointer items-center justify-center overflow-hidden rounded-xs border border-menu-primary bg-main-panel-bg shadow-xs",
      size === "md" && "size-5 rounded-md",
      (isSelected || isIndeterminate) && "border-transparent bg-brand-solid",
      // A disabled box keeps its own subtle fill in every state, so a checked
      // one never reads as an available brand action.
      isDisabled && "cursor-not-allowed border-disabled bg-disabled",
      isFocusVisible && "shadow-focus-brand-shadow-xs",
      className
    )}
    data-slot="checkbox-control"
  >
    <span
      className={cx(
        "pointer-events-none absolute flex items-center justify-center opacity-0",
        iconInsetClasses[size],
        isDisabled ? "text-fg-disabled" : "text-white",
        isIndeterminate && "opacity-100"
      )}
    >
      <MinusIcon className={iconClasses} />
    </span>
    <span
      className={cx(
        "pointer-events-none absolute flex items-center justify-center opacity-0",
        iconInsetClasses[size],
        isDisabled ? "text-fg-disabled" : "text-white",
        isSelected && !isIndeterminate && "opacity-100"
      )}
    >
      <CheckLargeIcon className={iconClasses} />
    </span>
  </div>
);
