import type { ToastVariant } from "./types";

/** Shared shell — Figma: bg-popup-primary, border-primary @ 0.5px */
export const toastShellBase =
  "flex w-full flex-col overflow-hidden border-[length:var(--border-width-0-5)] border-solid border-primary bg-popup-primary text-left";

export const toastShellVariant: Record<ToastVariant, string> = {
  single: "w-toast-single max-w-full rounded-2xl px-xl py-lg shadow-lg",
  description: "w-toast-single max-w-full rounded-2xl px-xl py-lg shadow-lg",
  action: "w-toast-action max-w-full gap-md rounded-xl px-xl py-lg shadow-md",
};

/** Text sm/Medium + Component colors/Components/Toast/text-primary — one title
    size across every toast variant (and the chat item cards they sit beside). */
export const toastTitleMd = "break-words text-sm font-medium text-toast-text-primary";

/** Figma: Text sm/Medium + Colors/Text/text-primary (900) */
export const toastTitleSmAction = "break-words text-sm font-medium text-primary";

/** Figma: Text sm/Regular + Component colors/Components/Toast/text-secondary */
export const toastDescription =
  "break-words text-sm font-regular text-toast-text-secondary";

export const toastRowGap = "gap-md";

/** 20px (--spacing-2xl) matches the 13px/20px text line box, so the status
    glyph aligns to the copy instead of overhanging it. */
export const toastStatusIcon = "size-2xl shrink-0";

export const toastCloseButton =
  "relative inline-flex size-3xl shrink-0 items-center justify-center rounded-sm text-toast-icon-primary " +
  "transition-colors hover:text-secondary focus:outline-none focus-visible:shadow-focus-gray-shadow-xs";

/** Indent keeps content below the title flush with it: status icon + row gap. */
export const toastContentRow =
  "flex w-toast-actions-row max-w-full pl-[calc(var(--spacing-2xl)+var(--spacing-md))]";

export const toastActionsRow = `${toastContentRow} items-center gap-md`;

/* The two action treatments below are shared with the chat item cards
   (send-failure row), so those inline actions read as the same control. */
/** Shared secondary chrome; each control owns its spacing and type scale. */
export const secondaryActionFrame =
  "inline-flex shrink-0 items-center justify-center overflow-hidden rounded-md " +
  "border border-button-secondary-border bg-button-secondary-bg " +
  "font-medium text-button-secondary-fg shadow-xs transition-colors " +
  "hover:bg-secondary focus:outline-none focus-visible:shadow-focus-gray-shadow-xs";

/** Single-button spacing without horizontal padding, which the surface supplies. */
export const secondaryActionTreatment = `${secondaryActionFrame} gap-xs py-xs text-sm`;

export const toastSecondaryAction = `${secondaryActionTreatment} px-md`;

export const toastTertiaryAction =
  "inline-flex shrink-0 items-center justify-center gap-sm overflow-hidden py-xs " +
  "text-sm font-medium text-button-tertiary-fg transition-colors " +
  "hover:text-secondary focus:outline-none focus-visible:shadow-focus-gray";
