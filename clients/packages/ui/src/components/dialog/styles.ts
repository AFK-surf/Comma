import type { CSSProperties } from "react";

/**
 * Dialog shell — Figma 7601:17310 / 7601:17311.
 * bg-popup-primary, border-primary @ 0.5px, radius-xl, shadow-md, spacing-xl padding,
 * spacing-2xl between the content block and the footer row.
 */
export const dialogShell =
  "relative m-0 flex flex-col gap-2xl overflow-hidden rounded-xl border-[0.5px] border-solid " +
  "border-primary bg-popup-primary p-xl text-left shadow-md outline-none";

/** Full-screen backdrop + centering container. */
export const dialogOverlay =
  "fixed inset-0 z-50 flex items-center justify-center bg-overlay-scrim p-xl outline-none";

/** Modal positioning wrapper from react-aria-components. */
export const dialogModal =
  "flex max-h-[calc(100vh-48px)] w-full max-w-full justify-center outline-none";

/** Title + description stack — Figma: spacing-xxs between the two lines. */
export const dialogHeader = "flex w-full flex-col gap-xxs";

/** Header + input/body group — Figma: spacing-lg between the header and the field. */
export const dialogContentGroup = "flex w-full flex-col gap-lg";

/** Figma: Text md/Semibold + Colors/Text/text-primary (900) */
export const dialogTitle = "break-words text-md font-semibold text-primary";

/** Figma: Text xs/Regular + Colors/Text/text-quarterary (500) */
export const dialogDescription = "break-words text-xs font-regular text-quaternary";

export const dialogActionsRow = "flex w-full flex-wrap items-center justify-end gap-md";

/** Figma 7724:26531 — leading action (e.g. Skip) left, remaining actions grouped right. */
export const dialogActionsRowSplit =
  "flex w-full flex-wrap items-center justify-between gap-md";

export const dialogActionsTrailingGroup =
  "flex flex-wrap items-center justify-end gap-md";

/**
 * Footer action button — Figma 7724:26629: 32px tall on 12px side padding,
 * shorter than the shared `md` button the rest of the app uses.
 */
export const dialogActionButton = "h-8 px-3";

/**
 * Footer shortcut keycap — Figma 7724:26557 (ESC) / 7724:26594 (enter).
 * Held one step below the Figma 32×20 chip so it reads as a hint inside the
 * 32px button rather than filling its whole content box.
 */
export const dialogShortcutKey =
  "inline-flex h-xl w-3xl shrink-0 items-center justify-center rounded-xs " +
  "font-sans text-micro font-medium leading-none";

export const dialogShortcutKeyTone = {
  /** On secondary/tertiary buttons — Figma: bg-quaternary + text-quarterary. */
  default: "bg-quaternary text-quaternary",
  /** On primary/destructive buttons — white overlays that read against the brand fill. */
  onPrimary: "bg-dialog-shortcut-on-primary-bg text-dialog-shortcut-on-primary-text",
} as const;

/**
 * Close control — the Settings modal's own (a tertiary-gray 40px target with a
 * 24px glyph and the sidebar-item hover fill), inset md so its glyph keeps the
 * dialog's xl padding on the title row.
 */
export const dialogCloseButton = "absolute top-md right-md [&_.comma-icon-slot]:size-6";

/** The Settings close control's hover fill. */
export const dialogCloseButtonStyle = {
  "--comma-button-hover-bg": "var(--color-sidebar-bg-item)",
} as CSSProperties;
