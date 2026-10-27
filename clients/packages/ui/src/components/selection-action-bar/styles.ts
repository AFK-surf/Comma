/**
 * Selection action pill — Figma Comma App 1193:11862. The bar owns the chrome
 * (border, fill, shadow) and each action supplies its own label plus keycaps,
 * so a single-action bar is pixel-identical to the Figma frame.
 */
export const selectionActionBar =
  "comma-selection-action-bar fixed z-50 inline-flex items-center rounded-md border border-primary bg-ai-input-panel-bg-input shadow-xs";

export const selectionActionBarAction =
  "inline-flex shrink-0 cursor-default items-center gap-xs rounded-md bg-transparent px-md py-xs outline-none transition-colors duration-[var(--motion-duration-feedback-in)] hover:bg-quaternary data-[pressed]:bg-quaternary-hover focus-visible:shadow-focus-gray motion-reduce:transition-none";

export const selectionActionBarLabel =
  "whitespace-nowrap text-sm leading-5 tracking-[-0.14px] text-primary";

export const selectionActionBarKeys = "inline-flex shrink-0 items-center gap-xxs";

const selectionActionBarKeyBase =
  "inline-flex shrink-0 items-center justify-center rounded-xs bg-quaternary font-sans text-xs font-medium leading-[18px] text-secondary";

/**
 * The keycap footprint is the 18px line box plus the vertical padding that
 * defines it. Single glyphs sit in that square rather than shrink-wrapping, so
 * a narrow letter and a wide symbol cannot drift apart — the same treatment
 * the tooltip keycaps use.
 *
 * Written out literally, and with underscores for the spaces calc() needs:
 * Tailwind scans source text, so a class assembled from a variable is never
 * generated at all.
 */
export const selectionActionBarKey = `${selectionActionBarKeyBase} size-[calc(18px_+_2_*_var(--spacing-xxs))]`;

/** Multi-character labels grow horizontally from that same square. */
export const selectionActionBarWideKey = `${selectionActionBarKeyBase} h-[calc(18px_+_2_*_var(--spacing-xxs))] min-w-[calc(18px_+_2_*_var(--spacing-xxs))] px-xs`;

export const selectionActionBarSeparator =
  "h-4 shrink-0 self-center border-l-[length:var(--border-width-0-5)] border-primary";

/**
 * With a reply field the pill grows into a card: the selected text on top,
 * the field and the actions on one row under it.
 */
export const selectionActionBarReply =
  "w-[360px] flex-col items-stretch gap-xs rounded-xl p-sm";

export const selectionActionBarExcerpt =
  "m-0 line-clamp-2 whitespace-pre-wrap border-l-2 border-primary px-md text-sm leading-5 text-secondary [overflow-wrap:anywhere]";

/** A question that wraps grows the field upward; the actions stay on its last line. */
export const selectionActionBarReplyRow = "flex min-w-0 items-end gap-xs";

/** Wraps long questions and grows with them, up to six lines before it scrolls. */
export const selectionActionBarReplyInput =
  "field-sizing-content block max-h-[calc(6_*_20px_+_2_*_var(--spacing-xs))] min-w-0 flex-1 resize-none border-0 bg-transparent px-md py-xs text-sm leading-5 text-primary outline-none [overflow-wrap:anywhere] placeholder:text-placeholder";

export const selectionActionBarReplyError =
  "m-0 px-md text-xs leading-[18px] text-error-primary";
