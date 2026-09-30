/**
 * Figma Buttons/Button at Drive's compact scale (xs vertical padding), minus
 * the label size: the toolbar sets text-xs, the empty-folder call to action
 * text-sm.
 */
export const driveSecondaryButton =
  "inline-flex shrink-0 items-center justify-center gap-xs overflow-hidden rounded-md " +
  "border border-button-secondary-border bg-button-secondary-bg px-md py-xs " +
  "font-medium text-button-secondary-fg shadow-xs transition-colors " +
  "hover:bg-secondary focus:outline-none focus-visible:shadow-focus-gray-shadow-xs";

export const drivePrimaryButton =
  "inline-flex shrink-0 items-center justify-center gap-xs overflow-hidden rounded-md " +
  "border border-button-primary-border bg-button-primary-bg px-md py-xs " +
  "font-medium text-button-primary-fg shadow-xs transition-colors " +
  "hover:bg-button-primary-bg-hover hover:border-button-primary-border-hover " +
  "focus:outline-none focus-visible:shadow-focus-brand-shadow-xs";
