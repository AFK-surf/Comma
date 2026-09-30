import type { ReactNode, RefObject } from "react";
import { Button as AriaButton, Focusable } from "react-aria-components";
import {
  HomeIcon,
  InboxIcon,
  ListChecksIcon,
  PuzzleIcon,
  SettingsIcon,
} from "../icons";
import { cx, definedProps } from "../utils";

/**
 * Rendered width of the icon rail. The product shell publishes it as
 * `--comma-sidebar-rail-width` so the layout slot and the shell's width math
 * read one value.
 */
export const LEFT_RAIL_WIDTH = 75;

export interface LeftRailItem {
  id: string;
  label: string;
  /** Keep the label accessible while showing only the visual content. */
  hideLabel?: boolean;
  /** SVG glyphs are sized to 20px; other content, such as avatars, keeps its size. */
  icon: ReactNode;
  /**
   * Circular unread pip at the top-right of the icon slot. Same blue as Inbox
   * row attention dots.
   */
  badge?: boolean;
  className?: string;
  href?: string;
  /** Anchors an item tooltip on the visible icon slot, not the full-width row. */
  iconRef?: RefObject<HTMLSpanElement | null>;
  selected?: boolean;
  /** Owns the press; a linked item then navigates through this, not its href. */
  onPress?: () => void;
}

export interface LeftRailProps {
  items?: LeftRailItem[];
  /** The item pinned to the foot of the rail (the product puts Settings there). */
  footerItem?: LeftRailItem;
  navLabel?: string;
}

export const leftRailNavClassName = "flex w-full min-w-0 flex-col items-center gap-xs";

const leftRailItemClassName = (item: LeftRailItem) =>
  cx(
    // The shell already insets the window by --spacing-md, so a matching left
    // padding would read as a double gap: the item keeps half of it on the
    // leading edge and pulls its centred content back toward the window.
    "group/left-rail-item flex w-full min-w-0 flex-col items-center justify-center overflow-hidden rounded-lg border-0 bg-transparent py-sm pl-xs pr-md no-underline outline-none focus-visible:shadow-focus-gray",
    item.className
  );

const LeftRailItemContent = ({ item }: { item: LeftRailItem }) => (
  <span className="flex w-full min-w-0 flex-col items-center gap-xxs">
    {/* The selected state paints the icon slot and lifts the label to the
        sidebar's highlight colour, the way the wide sidebar marked its row. */}
    <span
      className={cx(
        "relative flex shrink-0 items-center justify-center rounded-sm px-sm py-xs text-sidebar-icon-primary transition-colors duration-[50ms] [&_svg]:size-5",
        item.selected
          ? "bg-sidebar-bg-item"
          : "group-hover/left-rail-item:bg-sidebar-bg-item"
      )}
      data-slot="left-rail-item-icon"
      {...(item.iconRef ? { ref: item.iconRef } : {})}
    >
      {item.icon}
      {item.badge ? (
        <span
          aria-hidden="true"
          className="pointer-events-none absolute right-1 top-0.5 size-[7.2px] rounded-full bg-utility-brand-400 shadow-[0_0_0_1.5px_var(--color-bg-window)]"
          data-slot="left-rail-item-badge"
        />
      ) : null}
    </span>
    <span
      className={cx(
        item.hideLabel ? "sr-only" : "w-full truncate text-center text-xs font-medium",
        item.selected ? "text-sidebar-text-highlight" : "text-quaternary"
      )}
      data-slot="left-rail-item-label"
    >
      {item.label}
    </span>
  </span>
);

/** Icon-over-label rail item shared by the product shell and the specimen. */
export const LeftRailItemControl = ({ item }: { item: LeftRailItem }) => {
  const className = leftRailItemClassName(item);
  const stateProps = {
    "data-selected": item.selected ? "true" : "false",
    "data-slot": "left-rail-item",
  } as const;

  if (item.href) {
    return (
      <Focusable>
        <a
          aria-current={item.selected ? "page" : undefined}
          className={className}
          href={item.href}
          onClick={(event) => {
            if (!item.onPress) return;
            // The product routes the press through its router so window
            // history stays in step; the href keeps the item a link.
            event.preventDefault();
            item.onPress();
          }}
          {...stateProps}
        >
          <LeftRailItemContent item={item} />
        </a>
      </Focusable>
    );
  }

  return (
    <AriaButton
      {...definedProps({ onPress: item.onPress })}
      {...(item.selected ? { "aria-current": "page" as const } : {})}
      className={className}
      {...stateProps}
    >
      <LeftRailItemContent item={item} />
    </AriaButton>
  );
};

const defaultLeftRailItems: LeftRailItem[] = [
  { icon: <HomeIcon />, id: "home", label: "Home", selected: true },
  { icon: <InboxIcon />, id: "inbox", label: "Inbox" },
  { icon: <ListChecksIcon mode="raw" />, id: "tasks", label: "Tasks" },
  { icon: <PuzzleIcon />, id: "plugins", label: "Plugins" },
];

const defaultLeftRailFooterItem: LeftRailItem = {
  icon: <SettingsIcon />,
  id: "settings",
  label: "Settings",
};

/** The narrow app sidebar: a column of icon items with one item pinned to its foot. */
export const LeftRail = ({
  items = defaultLeftRailItems,
  footerItem = defaultLeftRailFooterItem,
  navLabel = "Primary",
}: LeftRailProps) => (
  <aside
    className="flex h-full shrink-0 flex-col items-center justify-between pt-sm"
    style={{ width: LEFT_RAIL_WIDTH }}
  >
    <nav aria-label={navLabel} className={leftRailNavClassName}>
      {items.map((item) => (
        <LeftRailItemControl item={item} key={item.id} />
      ))}
    </nav>
    <LeftRailItemControl item={footerItem} />
  </aside>
);
