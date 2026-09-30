import { useEffect, useLayoutEffect, useRef, type ReactNode } from "react";
import { Button } from "../Button";
import { ChevronLeftSmallIcon } from "../icons";
import { ScrollArea } from "../scroll-area";
import { isImeKeyEvent } from "../utils";
import { SettingsSectionView, type SettingsPanelSection } from "../settings-panel";

export interface SettingsDetailProps {
  /** Identity of the page on screen; a change swaps the stage. */
  id: string;
  title: string;
  description?: ReactNode;
  backLabel: string;
  onBack: () => void;
  /** Commit controls, kept in flow directly under the form they submit. */
  actions?: ReactNode;
  /** Content in the settings card grammar — the same rows as the page behind. */
  sections?: readonly SettingsPanelSection[];
  /** Runs when the reader presses Enter in a single-line text input. */
  onSubmit?: () => void;
  children: ReactNode;
}

/**
 * A second-level settings page. Settings is already a modal surface, so a form
 * opened from it used to stack a dialog on a dialog: two scrims, two escape
 * targets, and a form boxed into a window inside a window. This is the same
 * form given the whole content column, reached and left the way a page is.
 */
export const SettingsDetailView = ({
  title,
  description,
  backLabel,
  onBack,
  actions,
  sections,
  onSubmit,
  children,
}: SettingsDetailProps) => {
  const pageRef = useRef<HTMLDivElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);

  /*
   * The control that opened this page unmounts with the rows behind it, so
   * focus lands on the body — and the modal's focus scope answers that by
   * pulling focus to the first tabbable thing it can find, which is the
   * sidebar's search box. A menu or popover opener is later still: it restores
   * focus as it closes, to a control that no longer exists, leaving focus on
   * the modal where Escape closes Settings outright instead of stepping back
   * to the rows. Claim focus onto this page, then again after those have had
   * their turn, hence the frame. It lands on the page itself rather than a
   * control so nothing arrives pre-highlighted and the keys below still see
   * the event.
   */
  useLayoutEffect(() => {
    const page = pageRef.current;
    if (!page) return undefined;
    page.focus();
    const frame = requestAnimationFrame(() => {
      if (!page.contains(document.activeElement)) page.focus();
    });
    return () => cancelAnimationFrame(frame);
  }, []);

  // Bound on the element rather than through a JSX handler: the page is a
  // container, not a control, and this keeps the keys scoped to it either way.
  useEffect(() => {
    const element = pageRef.current;
    if (!element) return undefined;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onBack();
        return;
      }
      if (
        event.key === "Enter" &&
        onSubmit &&
        !event.defaultPrevented &&
        !isImeKeyEvent(event) &&
        !event.shiftKey &&
        !event.ctrlKey &&
        !event.altKey &&
        !event.metaKey &&
        event.target instanceof HTMLInputElement &&
        ["text", "password", "email", "url", "tel", "number"].includes(
          event.target.type
        )
      ) {
        event.preventDefault();
        onSubmit();
      }
    };
    element.addEventListener("keydown", onKeyDown);
    return () => element.removeEventListener("keydown", onKeyDown);
  }, [onBack, onSubmit]);

  return (
    <div
      className="flex size-full min-h-0 min-w-0 flex-col outline-none"
      data-slot="settings-detail"
      ref={pageRef}
      tabIndex={-1}
    >
      <ScrollArea
        className="min-h-0 flex-1"
        edgeEffect="mask"
        edgeMask={{ endSize: 96, startSize: 48 }}
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="size-full"
      >
        <div className="mx-auto flex w-[640px] max-w-full flex-col gap-3xl px-[calc(var(--spacing-xl)*2)] py-3xl">
          <div className="flex flex-col gap-xl" ref={headerRef}>
            {/* The chevron hangs into its own optical side bearing so the back
                label starts on the same edge as the title beneath it. */}
            <div className="-ml-xs flex">
              <Button
                hierarchy="link-gray"
                size="sm"
                iconLeading={<ChevronLeftSmallIcon />}
                onPress={onBack}
              >
                {backLabel}
              </Button>
            </div>
            <div className="flex flex-col gap-xs">
              <h1 className="m-0 text-balance text-xl font-medium text-primary">
                {title}
              </h1>
              {description ? (
                <p className="m-0 text-pretty text-sm text-tertiary">{description}</p>
              ) : null}
            </div>
          </div>
          {sections?.length ? (
            <div className="flex w-full flex-col gap-3xl">
              {sections.map((section) => (
                <SettingsSectionView key={section.id} section={section} />
              ))}
            </div>
          ) : null}
          {children}
          {actions ? (
            // Trailing edge of the content, the way a card's own footer sits.
            <div
              className="flex flex-wrap justify-end gap-md"
              data-slot="settings-detail-actions"
            >
              {actions}
            </div>
          ) : null}
        </div>
      </ScrollArea>
    </div>
  );
};
