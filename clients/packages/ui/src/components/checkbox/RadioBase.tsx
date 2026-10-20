import { cx } from "../utils";

export type RadioBaseProps = {
  className?: string;
  isSelected?: boolean;
  isDisabled?: boolean;
};

/**
 * Comma radio as the checkbox's sibling (`CheckboxBase`): the same 16px control on the panel fill with the darker
 * menu border and the xs shadow, round, and filled brand-solid with a white dot when selected. Visual only: the
 * native input beside it carries the state, focus and keyboard.
 */
export const RadioBase = ({ className, isSelected, isDisabled }: RadioBaseProps) => (
  <span
    aria-hidden="true"
    className={cx(
      "relative flex size-4 shrink-0 items-center justify-center rounded-full border border-menu-primary bg-main-panel-bg shadow-xs",
      isSelected && "border-transparent bg-brand-solid",
      isDisabled && "border-disabled bg-disabled",
      className
    )}
    data-slot="radio-control"
  >
    <span
      className={cx(
        "size-1.5 rounded-full",
        isSelected ? (isDisabled ? "bg-fg-disabled" : "bg-white") : "bg-transparent"
      )}
    />
  </span>
);
