import { cx, sortCx } from "../utils";

type ToggleBaseProps = {
  size?: "sm" | "md";
  slim?: boolean;
  className?: string;
  isHovered?: boolean;
  isFocusVisible?: boolean;
  isSelected?: boolean;
  isDisabled?: boolean;
};

/**
 * Each variant only declares its track box plus the knob's diameter and inset;
 * the knob's two resting positions are derived from those in CSS, so a size
 * change never needs a matching travel constant.
 */
const trackStyles = sortCx({
  default: {
    sm: {
      root: "h-5 w-9 [--comma-toggle-thumb-size:16px] [--comma-toggle-thumb-inset:2px]",
    },
    md: {
      root: "h-6 w-11 [--comma-toggle-thumb-size:20px] [--comma-toggle-thumb-inset:2px]",
    },
  },
  slim: {
    sm: {
      root: "h-4 w-8 [--comma-toggle-thumb-size:16px] [--comma-toggle-thumb-inset:0px]",
    },
    md: {
      root: "h-5.5 w-9 [--comma-toggle-thumb-size:18px] [--comma-toggle-thumb-inset:2px]",
    },
  },
});

export const ToggleBase = ({
  className,
  isHovered,
  isDisabled,
  isFocusVisible,
  isSelected,
  slim,
  size = "sm",
}: ToggleBaseProps) => {
  const variant = slim ? trackStyles.slim[size] : trackStyles.default[size];

  return (
    <div
      className={cx(
        "comma-toggle cursor-pointer rounded-full",
        // Hover darkens the track with a translucent overlay (styles.css) so
        // both states share one treatment; no per-state hover color swap here.
        isSelected ? "bg-brand-solid" : "bg-toggle",
        slim && "ring-1 ring-inset",
        // Hover hides both hairlines — the track's ring and the knob's border —
        // so the control reads as one solid shape while the pointer is on it.
        // Hidden by color only: their widths never change, so nothing pops.
        slim && (isSelected || isHovered ? "ring-transparent" : "ring-primary"),
        // Dimming is delayed (styles.css) so a preference write that resolves
        // quickly never flashes the control, while the control is genuinely
        // disabled the whole time.
        isDisabled && "comma-toggle-disabled cursor-not-allowed opacity-50",
        isFocusVisible && "shadow-focus-brand",
        variant.root,
        className
      )}
      data-disabled={isDisabled ? "true" : "false"}
      data-selected={isSelected ? "true" : "false"}
      data-slot="toggle-base"
    >
      <div className="comma-toggle-thumb-motion" data-slot="toggle-thumb-motion">
        <div
          className={cx(
            "comma-toggle-thumb size-full shadow-sm",
            isDisabled ? "bg-toggle-button-fg-disabled" : "bg-fg-white",
            slim && "shadow-xs",
            // The border is always present and only its color changes: removing
            // the class made the width pop and flashed the preflight
            // currentColor (near-black) through the border-color transition on
            // every hover exit.
            slim && "border",
            slim && (isSelected || isHovered ? "border-transparent" : "border-primary")
          )}
          data-slot="toggle-thumb"
        />
      </div>
    </div>
  );
};
