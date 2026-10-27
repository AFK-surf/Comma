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

/**
 * Compose shell — Linear's New issue: the default shell's surface with softer
 * corners and tighter insets, the breadcrumb row lg from the top and the body
 * lg below it. A whole class list rather than overrides of `dialogShell`:
 * tailwind-merge does not see the theme's named sizes (`rounded-xl` against
 * `rounded-2xl`, `w-dialog-default` against `w-dialog-compose`) as one group.
 */
export const dialogComposeShell =
  "relative m-0 flex w-dialog-compose max-w-full flex-col gap-lg overflow-hidden rounded-2xl " +
  "border-[0.5px] border-solid border-primary bg-popup-primary px-xl py-lg text-left shadow-md outline-none";

/** Compose title row: the leading chip, a chevron, then the title, one chip tall (3xl and xs, the Tasks toolbar's button). */
export const dialogComposeHeader =
  "flex h-[calc(var(--spacing-3xl)+var(--spacing-xs))] w-full min-w-0 items-center gap-xs";

/** Compose title: the breadcrumb's last step, set like its text rather than as a heading. */
export const dialogComposeTitle = "truncate text-sm font-regular text-primary";

/**
 * Compact close control: an xs (4xl) icon button centred on the compose title row, lg from the top. Its glyph is
 * 20px, a step up from xs's 16px, so it reads beside the title as the default dialog's does.
 */
export const dialogComposeCloseButton =
  "absolute top-[calc(var(--spacing-lg)-var(--spacing-xxs))] right-md [&_.comma-icon-slot]:size-5";

/** The Settings close control's hover fill. */
export const dialogCloseButtonStyle = {
  "--comma-button-hover-bg": "var(--color-sidebar-bg-item)",
} as CSSProperties;
