import type { ReactNode } from "react";
import { XIcon } from "../icons";
import { cx } from "../utils";

/** Figma Buttons/Button in its pill shape; press feedback is a subtle scale. */
export const selectionBarButtonClasses =
  "inline-flex shrink-0 items-center justify-center gap-xs overflow-hidden rounded-full " +
  "border border-button-secondary-border bg-button-secondary-bg py-xs text-sm font-medium " +
  "text-button-secondary-fg shadow-xs transition-[background-color,scale] duration-[160ms] " +
  "ease-[cubic-bezier(0.23,1,0.32,1)] hover:bg-secondary active:scale-[0.97] " +
  "focus:outline-none focus-visible:shadow-focus-gray-shadow-xs motion-reduce:transition-none";

export interface SelectionBarProps {
  /** The toolbar's accessible name ("Selected files", "Selected tasks"). */
  "aria-label": string;
  /** The action pills between the count and the close. */
  children?: ReactNode;
  /** Accessible name of the close control. */
  clearLabel: string;
  clearTestId?: string | undefined;
  /** "3 selected", already localized. */
  countLabel: string;
  onClear: () => void;
  testId?: string | undefined;
}

/**
 * Floats over a list once anything is checked (Figma 1371:19684): the count,
 * the actions that apply to the whole selection, and a close. It enters from
 * a few pixels below with a short ease-out so it reads as arriving for the
 * selection rather than popping into place.
 */
export function SelectionBar({
  "aria-label": ariaLabel,
  children,
  clearLabel,
  clearTestId,
  countLabel,
  onClear,
  testId,
}: SelectionBarProps) {
  return (
    <div
      aria-label={ariaLabel}
      className={cx(
        "absolute bottom-3xl left-1/2 z-[8] flex -translate-x-1/2 items-center gap-md",
        "rounded-full border-[length:var(--border-width-0-5)] border-solid border-primary bg-popup-secondary py-sm pl-xl pr-lg shadow-xs",
        "transition-[opacity,translate] duration-[160ms] ease-[cubic-bezier(0.23,1,0.32,1)] starting:translate-y-2 starting:opacity-0 motion-reduce:transition-none"
      )}
      data-slot="selection-bar"
      data-testid={testId}
      role="toolbar"
    >
      <span className="text-sm whitespace-nowrap text-primary">{countLabel}</span>
      {children}
      <button
        aria-label={clearLabel}
        className="inline-flex size-6 shrink-0 items-center justify-center rounded-sm border-0 bg-transparent p-0 text-quaternary outline-none transition-colors duration-[160ms] hover:text-secondary focus-visible:shadow-focus-gray"
        data-testid={clearTestId}
        onClick={onClear}
        type="button"
      >
        <XIcon aria-hidden className="size-6" />
      </button>
    </div>
  );
}
