// The chrome a structured file preview (CSV, JSON, notebook, archive, TIFF) shares around its own body: the notice
// that says what was left out, the centered empty or failed state, the view toggle and actions in the panel toolbar,
// and the way a link in the file opens. One look for every type: a type
// builds its body and composes these, and does not restyle them.
import { CircleInfoIcon } from "@comma/ui/components/icons";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { useMemo, type MouseEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { ShellIconButtonControl } from "../ShellIconButton";
import { opensInBrowser } from "./wholeFile";

/**
 * What the preview leaves out, or another fact about what it shows ("Showing the first 500 rows…"). It sits under
 * the status bar (or the panel header), above the body, and does not scroll with it. Quieter than the status bar's
 * meta: the panel's own background, with an info mark.
 */
export function PreviewNotice({
  children,
  testId,
}: {
  children: ReactNode;
  testId?: string | undefined;
}) {
  return (
    <div
      className="flex shrink-0 items-start gap-sm border-b-[length:var(--border-width-0-5)] border-secondary bg-primary px-xl py-sm text-xs text-tertiary"
      data-testid={testId}
      role="note"
    >
      <span
        aria-hidden
        className="flex h-(--text-xs--line-height) shrink-0 items-center"
      >
        <CircleInfoIcon className="size-3.5 text-fg-quaternary" />
      </span>
      <span className="min-w-0 flex-1">{children}</span>
    </div>
  );
}

/**
 * A state in the middle of the preview in place of its body: empty, failed, too large. It reads as the other viewers'
 * (`RenderedFilePreview`'s) failure does, a line of secondary text, with an optional mark above it. `alert` announces
 * a failure; an empty file is not one.
 *
 * It fills the space it is given (`flex-1`): put it where the body would be, inside the scroll when `children` of the
 * preview follow it.
 */
export function PreviewMessage({
  children,
  icon,
  alert = false,
  testId,
}: {
  children: ReactNode;
  /** A glyph (size is set here), e.g. `<InboxIcon />` for an empty archive. */
  icon?: ReactNode;
  alert?: boolean;
  testId?: string | undefined;
}) {
  return (
    <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-sm p-xl text-center">
      {icon ? (
        <span
          aria-hidden
          className="comma-icon-slot inline-flex size-5 text-fg-quaternary [&_svg]:size-full"
        >
          {icon}
        </span>
      ) : null}
      <p
        className="m-0 max-w-(--container-xs) text-sm text-secondary"
        data-testid={testId}
        role={alert ? "alert" : undefined}
      >
        {children}
      </p>
    </div>
  );
}

export type PreviewViewOption<T extends string> = {
  value: T;
  /** The button's accessible name and tooltip. */
  label: string;
  icon: ReactNode;
};

/**
 * Switches between a preview's views (structured / source): a segmented control in the panel toolbar, a quiet track
 * with the current view raised on it, sized to sit beside the toolbar's icon buttons. Render it into the panel
 * toolbar with `PreviewToolbarPortal`.
 */
export function PreviewViewToggle<T extends string>({
  label,
  value,
  options,
  onChange,
  testId,
}: {
  /** The group's accessible name. */
  label: string;
  value: T;
  options: readonly PreviewViewOption<T>[];
  onChange: (value: T) => void;
  testId?: string | undefined;
}) {
  return (
    <fieldset
      aria-label={label}
      className="m-0 flex min-w-0 shrink-0 items-center gap-xxs rounded-md border-0 bg-quaternary p-xxs dark:bg-secondary"
      data-testid={testId}
    >
      {options.map((option) => {
        const pressed = option.value === value;
        return (
          <Tooltip content={option.label} key={option.value} placement="bottom">
            <button
              aria-label={option.label}
              aria-pressed={pressed}
              className={cx(
                "inline-flex size-6 items-center justify-center rounded-sm border-0 outline-none transition-colors focus-visible:shadow-focus-gray [&_svg]:size-4",
                pressed
                  ? "bg-primary text-fg-primary shadow-xs dark:bg-quaternary"
                  : "bg-transparent text-fg-tertiary hover:text-fg-primary"
              )}
              onClick={() => onChange(option.value)}
              type="button"
            >
              {option.icon}
            </button>
          </Tooltip>
        );
      })}
    </fieldset>
  );
}

/**
 * An icon action in the panel toolbar (Expand all, Collapse all): the toolbar's own icon button, with its label as
 * tooltip and accessible name. Render it with `PreviewToolbarPortal`.
 */
export function PreviewToolbarAction({
  label,
  icon,
  onPress,
  testId,
}: {
  label: string;
  icon: ReactNode;
  onPress: () => void;
  testId?: string | undefined;
}) {
  return (
    <Tooltip content={label} placement="bottom">
      <ShellIconButtonControl
        aria-label={label}
        data-testid={testId}
        icon={icon}
        onPress={onPress}
      />
    </Tooltip>
  );
}

/** Renders a viewer's controls into the panel toolbar's slot (`toolbarSlot`), or nowhere while there is none. */
export function PreviewToolbarPortal({
  slot,
  children,
}: {
  slot: HTMLElement | null | undefined;
  children: ReactNode;
}) {
  return slot ? createPortal(children, slot) : null;
}

/**
 * Link handling for a preview body that renders the file's own links: a click on a web or mailto link opens it in
 * the browser (`onOpenBrowser`), any other link does nothing, and a middle click never opens one in a window of the
 * app. Spread the result on the element that holds the body.
 */
export function usePreviewLinkHandlers(onOpenBrowser: (url: string) => void) {
  return useMemo(
    () => ({
      onAuxClick: (event: MouseEvent) => {
        if (event.target instanceof Element && event.target.closest("a[href]"))
          event.preventDefault();
      },
      onClickCapture: (event: MouseEvent) => {
        const link =
          event.target instanceof Element ? event.target.closest("a[href]") : null;
        if (!(link instanceof HTMLAnchorElement)) return;
        event.preventDefault();
        event.stopPropagation();
        if (opensInBrowser(link.href)) onOpenBrowser(link.href);
      },
    }),
    [onOpenBrowser]
  );
}
