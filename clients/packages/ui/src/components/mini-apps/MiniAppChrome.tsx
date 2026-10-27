import { useCommaMessages } from "@comma/i18n/react";
import type { ReactNode } from "react";
import { Button } from "../Button";
import { MoreHorizontalIcon, SquareGridCircleIcon } from "../icons";
import { Avatar } from "../avatar";
import { Menu, MenuItem, MenuPopover, MenuTrigger, menuSurfaceClasses } from "../menu";
import { cx } from "../utils";

export type MiniAppChromeAction = { id: string; label: string; onAction: () => void };

export type MiniAppChromeProps = {
  name: string;
  author: string;
  /** The app's own icon. Without one the bar shows no icon: a generic glyph would tell every app apart from nothing. */
  iconUrl?: string | null | undefined;
  /** Which Version this is when it is not the live one, as a Task card's "· 3". */
  detail?: string | undefined;
  /** Extra entries of the actions menu (open modes, settings); Report always ends it. */
  actions?: readonly MiniAppChromeAction[] | undefined;
  /** Controls at the start of the bar, before the name (a back button, a window's traffic-light slot). */
  leading?: ReactNode;
  /** Classes for the bar (a window's title bar: its drag region and traffic-light inset). */
  headerClassName?: string | undefined;
  /** Controls at the end of the bar, before the menu. */
  trailing?: ReactNode;
  /** Controls under the app, inside the chrome (a Task card's open modes and Publish). */
  footer?: ReactNode;
  /**
   * `card` draws its own frame, for an app among other content. `flush` has no frame and fills a surface that already
   * has one (the right panel, a window): its bar is that surface's 44px header. `cover` is an app's launch cover in a
   * chat: the app's first screen as the cover, then a row with the app's icon, name and detail, `trailing` (Open) and
   * the menu.
   */
  variant?: "card" | "flush" | "cover" | undefined;
  /** `cover`: what a press anywhere on the card does (open the app), and its accessible name. The menu stays its own. */
  onOpen?: (() => void) | undefined;
  openLabel?: string | undefined;
  /** The app's height (a chat card's preview); the app fills the chrome otherwise. */
  bodyHeight?: number | undefined;
  onReport: () => void;
  className?: string | undefined;
  children?: ReactNode;
};

/**
 * The host chrome around every running app: its name, and an actions menu that always offers Report and ends with who
 * made the app. An app cannot draw over it, so a viewer always knows which app they use and who made it.
 */
export function MiniAppChrome({
  name,
  author,
  iconUrl,
  detail,
  actions = [],
  leading,
  headerClassName,
  trailing,
  footer,
  variant = "card",
  bodyHeight,
  onOpen,
  openLabel,
  onReport,
  className,
  children,
}: MiniAppChromeProps) {
  const messages = useCommaMessages();
  const menu = (
    <MenuTrigger>
      <Button
        aria-label={messages.mini_app_actions()}
        hierarchy="tertiary-gray"
        iconLeading={<MoreHorizontalIcon />}
        iconOnly
        size="xs"
      />
      <MenuPopover
        className={cx("w-fit min-w-44 overflow-hidden", menuSurfaceClasses)}
        placement="bottom end"
      >
        <Menu
          aria-label={messages.mini_app_actions()}
          className="py-sm"
          variant="embedded"
          onAction={(key) => {
            if (key === "report") onReport();
            else actions.find((action) => action.id === key)?.onAction();
          }}
        >
          {actions.map((action) => (
            <MenuItem id={action.id} key={action.id}>
              {action.label}
            </MenuItem>
          ))}
          <MenuItem id="report" tone="destructive">
            {messages.mini_app_report()}
          </MenuItem>
        </Menu>
        {/* Who made it, at the menu's foot as a page's "Last edited" is: not an action. */}
        {author ? (
          <div className="flex flex-col gap-sm border-t-[0.5px] border-primary py-md pr-lg pl-[calc(var(--spacing-sm)+var(--spacing-md))]">
            <p className="text-xs text-quaternary">{messages.mini_app_made_by()}</p>
            <span className="flex min-w-0 items-center gap-sm">
              <Avatar name={author} size="xs" />
              <span className="truncate text-sm text-primary">{author}</span>
            </span>
          </div>
        ) : null}
      </MenuPopover>
    </MenuTrigger>
  );
  return (
    <section
      aria-label={name}
      className={cx(
        "flex min-w-0 flex-col overflow-hidden bg-primary",
        variant === "cover" &&
          "group/cover relative has-[>button:focus-visible]:shadow-focus-gray-shadow-xs",
        // The card's corner is its footer buttons' corner plus the footer's inset (8 + 8).
        variant === "flush"
          ? "min-h-0 flex-1"
          : "rounded-2xl shadow-xs ring-1 ring-primary",
        className
      )}
      data-testid="mini-app-chrome"
      data-variant={variant}
    >
      {/* First, so Tab reaches the card's open before its menu; above the app, under the menu. Its focus ring is the
          card's own: one drawn on the button would sit outside it and be cut off by the card's edge. */}
      {variant === "cover" && onOpen ? (
        <button
          aria-label={openLabel}
          className="absolute inset-0 z-[1] cursor-pointer outline-none"
          data-no-press-feedback
          data-testid="mini-app-card-open"
          onClick={onOpen}
          type="button"
        />
      ) : null}
      {variant !== "cover" ? (
        <header
          className={cx(
            "flex h-11 min-w-0 shrink-0 items-center gap-sm border-b-[0.5px] border-primary",
            variant === "card" ? "pr-sm pl-lg" : "pr-md pl-xl",
            headerClassName
          )}
        >
          {leading}
          {iconUrl ? (
            <img
              alt=""
              className="size-6 shrink-0 rounded-md object-cover outline-1 -outline-offset-1 outline-black/10 dark:outline-white/10"
              src={iconUrl}
            />
          ) : null}
          <span className="flex min-w-0 flex-1 items-baseline gap-xs">
            <span className="truncate text-sm font-medium text-primary">{name}</span>
            {detail ? (
              <span className="shrink-0 text-xs text-tertiary">{detail}</span>
            ) : null}
          </span>
          {trailing}
          {menu}
        </header>
      ) : null}
      <div
        className={cx(
          "relative flex min-w-0 flex-col",
          bodyHeight === undefined ? "min-h-0 flex-1" : "shrink-0"
        )}
        data-testid="mini-app-body"
        style={bodyHeight === undefined ? undefined : { height: bodyHeight }}
      >
        {variant === "cover" ? <CoverStage>{children}</CoverStage> : children}
      </div>
      {variant === "cover" ? (
        <div className="flex h-16 min-w-0 shrink-0 items-center gap-md border-t-[0.5px] border-primary pr-sm pl-lg">
          {/* The app's icon, or the app glyph on a tile: a launch cover always shows one. */}
          {iconUrl ? (
            <img
              alt=""
              className="size-10 shrink-0 rounded-xl object-cover outline-1 -outline-offset-1 outline-black/10 dark:outline-white/10"
              src={iconUrl}
            />
          ) : (
            <span
              aria-hidden
              className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-tertiary"
            >
              <SquareGridCircleIcon className="size-5 text-fg-quaternary" />
            </span>
          )}
          <span className="flex min-w-0 flex-1 flex-col">
            <span className="truncate text-sm font-medium text-primary">{name}</span>
            {detail ? (
              <span className="truncate text-xs text-tertiary">{detail}</span>
            ) : null}
          </span>
          {/* Above the card's open button, so a press on them is their own. */}
          <span className="relative z-10 flex shrink-0 items-center gap-md">
            {trailing}
            {menu}
          </span>
        </div>
      ) : null}
      {footer ? (
        <footer className="flex min-w-0 shrink-0 flex-wrap items-center gap-sm border-t-[0.5px] border-primary p-md">
          {footer}
        </footer>
      ) : null}
    </section>
  );
}

/** The cover's phone: the app runs at an iPhone's width, so it lays out as its phone app, and shows at 60%. */
const PHONE_WIDTH = 390;
const PHONE_HEIGHT = 844;
const PHONE_SCALE = 0.6;

/**
 * A launch cover's stage: the app's first screen on a phone, shown smaller on a gray ground and cut off by the cover's
 * bottom edge, as an App Store screenshot is. It darkens while the pointer is on the card's open: anywhere on the card
 * but its menu.
 */
function CoverStage({ children }: { children: ReactNode }) {
  return (
    <div className="relative flex min-h-0 flex-1 justify-center overflow-hidden bg-tertiary pt-xl transition-colors group-has-[>button:hover]/cover:bg-quaternary">
      <div
        className="h-full shrink-0 overflow-hidden rounded-t-2xl bg-primary shadow-sm ring-1 ring-primary"
        style={{ width: PHONE_WIDTH * PHONE_SCALE }}
      >
        <div
          className="flex origin-top-left flex-col"
          style={{
            width: PHONE_WIDTH,
            height: PHONE_HEIGHT,
            transform: `scale(${PHONE_SCALE})`,
          }}
        >
          {children}
        </div>
      </div>
    </div>
  );
}
