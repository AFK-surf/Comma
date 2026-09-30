import { cx } from "@comma/ui";

/**
 * The tab in a panel toolbar: a pill that fills in when it is the one
 * showing, rather than an underline. Drive's transfer panel and sync history
 * switch views with it, and the billing period switch reads the same way, so
 * one control means "which of these lists am I looking at" across the app.
 */
export const panelTabButton = (active: boolean) =>
  cx(
    "inline-flex shrink-0 items-center justify-center rounded-md border-0 px-md py-xs text-sm font-medium transition-colors",
    "focus:outline-none focus-visible:shadow-focus-gray",
    "disabled:cursor-default disabled:opacity-[var(--opacity-disabled)]",
    active
      ? "bg-quaternary text-primary"
      : "bg-transparent text-button-tertiary-fg hover:text-primary"
  );
