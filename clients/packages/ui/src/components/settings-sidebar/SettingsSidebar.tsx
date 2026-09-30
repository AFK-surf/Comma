import { memo, useCallback, useLayoutEffect, useRef } from "react";
import {
  SettingsSidebarItemControl,
  type SettingsSidebarItem,
} from "./SettingsSidebarItemControl";
import { SearchIcon } from "../icons";
import { InputField } from "../input";
import { ScrollArea } from "../scroll-area";
import { cx } from "../utils";

export interface SettingsSidebarGroup {
  id: string;
  items: SettingsSidebarItem[];
  label?: string;
}

export interface SettingsSidebarSearchItem {
  context?: string;
  id: string;
  onPress: () => void;
  title: string;
}

export interface SettingsSidebarSearchGroup {
  id: string;
  items: SettingsSidebarSearchItem[];
  label?: string;
}

export type SettingsSidebarLayout = "rail" | "tabs";

export interface SettingsSidebarProps {
  ariaLabel?: string;
  className?: string;
  groups?: SettingsSidebarGroup[];
  items?: SettingsSidebarItem[];
  /** "tabs" lays the categories out as one scrolling row above the content. */
  layout?: SettingsSidebarLayout;
  onSearchChange?: (value: string) => void;
  searchAriaLabel?: string;
  searchEmptyDescription?: string;
  searchEmptyTitle?: string;
  searchGroups?: SettingsSidebarSearchGroup[];
  searchPlaceholder?: string;
  searchValue?: string;
  title?: string;
}

const selectedTabScrollOptions: ScrollIntoViewOptions = {
  block: "nearest",
  inline: "nearest",
};

/** One category of the tab row: the rail's row stripped to its label. */
const SettingsTab = ({ item }: { item: SettingsSidebarItem }) => {
  const tabRef = useRef<HTMLButtonElement | null>(null);
  // The row scrolls sideways, and a deep link or a palette jump can select a
  // category past its end. The selected tab brings itself into view as it
  // becomes selected — which includes the row's first paint after the card
  // narrows from the rail. The row's `ScrollArea` re-reveals it as the row
  // settles (see `revealSelectedTab`); the viewport's scroll padding keeps it
  // clear of the row's edge masks.
  useLayoutEffect(() => {
    if (!item.selected) return;
    tabRef.current?.scrollIntoView(selectedTabScrollOptions);
  }, [item.selected]);

  return (
    <button
      className={cx(
        "flex h-8 shrink-0 items-center whitespace-nowrap rounded-lg border-0 bg-transparent px-md text-sm leading-5 tracking-[-0.14px] outline-none transition-colors duration-[50ms] focus-visible:shadow-focus-gray",
        item.selected
          ? "bg-sidebar-bg-item text-sidebar-text-highlight"
          : "text-sidebar-text-secondary hover:bg-sidebar-bg-item hover:text-sidebar-text-highlight",
        item.className
      )}
      data-selected={item.selected ? "true" : "false"}
      data-slot="settings-tab"
      onClick={item.onPress}
      ref={tabRef}
      type="button"
      {...(item.selected ? { "aria-current": "page" as const } : {})}
    >
      {item.label}
    </button>
  );
};

/**
 * Memoized: Settings rebuilds its registry on every change inside a category,
 * and the page passes the same props until the categories or search change.
 */
export const SettingsSidebar = memo(function SettingsSidebar({
  ariaLabel = "Settings sections",
  className,
  groups,
  items = [],
  layout = "rail",
  onSearchChange,
  searchAriaLabel = "Search settings",
  searchEmptyDescription,
  searchEmptyTitle = "No settings found",
  searchGroups,
  searchPlaceholder = "Search settings",
  searchValue,
  title,
}: SettingsSidebarProps) {
  const resolvedGroups =
    groups ??
    (items.length > 0
      ? [{ id: "settings", items, ...(title ? { label: title } : {}) }]
      : []);
  const normalizedSearchValue = searchValue?.trim() ?? "";
  // A tab row carries the categories alone: the row is the whole chrome a
  // narrow card can spare, so there is no search field above it and nothing to
  // render results for.
  const tabRow = layout === "tabs";
  const showSearchResults =
    !tabRow && normalizedSearchValue.length > 0 && searchGroups !== undefined;
  const navRef = useRef<HTMLElement | null>(null);
  // The row is still settling when the selected tab first scrolls to itself:
  // its viewport narrows once the scroll area lays out its own chrome, and
  // the tabs re-measure when the row's font arrives. The scroll area's shared
  // measurement reports both, so the selected tab is revealed again then.
  const revealSelectedTab = useCallback(() => {
    navRef.current
      ?.querySelector<HTMLElement>('[data-slot="settings-tab"][data-selected="true"]')
      ?.scrollIntoView(selectedTabScrollOptions);
  }, []);

  return (
    <aside
      aria-label={ariaLabel}
      className={cx(
        "comma-settings-sidebar flex min-w-0 shrink-0 flex-col",
        layout === "tabs"
          ? // The card's close control sits in this row's trailing corner, so the
            // row reserves its inset, its box and a gap. At 48px the row leaves
            // that 40px box an xs inset top and bottom, centred on the tabs.
            "w-full min-h-[var(--spacing-6xl)] border-b-[0.5px] border-primary pl-lg pr-[calc(var(--spacing-lg)+var(--spacing-5xl)+var(--spacing-sm))]"
          : "h-full w-[286px] min-w-[220px] pb-none pl-lg pr-lg pt-lg",
        className
      )}
      data-layout={layout}
    >
      {tabRow ? null : (
        <form className="mb-xl px-none" onSubmit={(event) => event.preventDefault()}>
          <InputField
            aria-label={searchAriaLabel}
            className="w-full"
            fieldSize="sm"
            leadingIcon={<SearchIcon className="size-4" />}
            onChange={(event) => onSearchChange?.(event.target.value)}
            placeholder={searchPlaceholder}
            suppressFocusRing={false}
            type="search"
            {...(searchValue !== undefined ? { value: searchValue } : {})}
          />
        </form>
      )}
      <ScrollArea
        className={cx(tabRow ? "min-w-0 flex-1" : "min-h-0 flex-1")}
        edgeEffect="mask"
        edgeMask={{ endSize: 24, startSize: 8 }}
        orientation={tabRow ? "horizontal" : "vertical"}
        // The row fills the bar so its scrollbar rides the divider below the
        // tabs rather than floating under them, and sits flush against it.
        {...(tabRow
          ? {
              contentClassName: "flex h-full items-center",
              onContentResize: revealSelectedTab,
              onViewportResize: revealSelectedTab,
              scrollbar: { inset: 0 },
            }
          : {})}
        scrollbarVisibility="hover"
        // The tab row's scroll padding mirrors its edge masks (md at the
        // start, 3xl at the end), so a tab scrolled into view lands clear
        // of the fade rather than under it.
        viewportClassName={cx("size-full", tabRow && "scroll-ps-md scroll-pe-3xl")}
      >
        <nav
          aria-label={ariaLabel}
          className={cx(
            // Scroll padding needs trailing space in the content as well so
            // the last tab can be revealed clear of the row's end mask.
            tabRow
              ? "flex w-max items-center gap-xs pe-3xl"
              : "flex flex-col gap-xl pb-xl pr-[calc(var(--scroll-area-scrollbar-size)+var(--scroll-area-scrollbar-inset)+var(--spacing-xs))]"
          )}
          ref={navRef}
        >
          {showSearchResults ? (
            searchGroups.length > 0 ? (
              <div className="flex flex-col gap-xl" data-slot="settings-search-results">
                {searchGroups.map((group) => (
                  <section
                    className="flex flex-col gap-xxs"
                    key={group.id}
                    {...(group.label
                      ? {
                          "aria-labelledby": `settings-search-group-${group.id}`,
                        }
                      : {})}
                  >
                    {group.label ? (
                      <p
                        className="mb-sm px-md text-sm font-medium text-quaternary"
                        id={`settings-search-group-${group.id}`}
                      >
                        {group.label}
                      </p>
                    ) : null}
                    {group.items.map((item) => (
                      <button
                        className="flex w-full flex-col gap-xxs rounded-lg border-0 bg-transparent px-md py-sm text-left outline-none hover:bg-sidebar-bg-item focus-visible:shadow-focus-gray"
                        key={item.id}
                        onClick={item.onPress}
                        type="button"
                      >
                        <span className="line-clamp-2 text-sm text-sidebar-text-highlight">
                          {item.title}
                        </span>
                        {item.context ? (
                          <span className="line-clamp-2 text-xs text-sidebar-text-secondary">
                            {item.context}
                          </span>
                        ) : null}
                      </button>
                    ))}
                  </section>
                ))}
              </div>
            ) : (
              <div
                className="flex flex-col gap-xs px-md py-xl text-center"
                data-slot="settings-search-empty"
              >
                <p className="text-sm font-medium text-primary">{searchEmptyTitle}</p>
                {searchEmptyDescription ? (
                  <p className="text-xs text-quaternary">{searchEmptyDescription}</p>
                ) : null}
              </div>
            )
          ) : tabRow ? (
            // One row leaves no place for the group headings, and an icon per
            // tab would push most of the categories off the end of the scroll.
            resolvedGroups
              .flatMap((group) => group.items)
              .map((item) => <SettingsTab item={item} key={item.id} />)
          ) : (
            resolvedGroups.map((group) => (
              <div className="flex flex-col gap-xxs" key={group.id}>
                {group.label ? (
                  <p className="m-none px-md text-sm font-medium text-quaternary">
                    {group.label}
                  </p>
                ) : null}
                <div className="flex flex-col gap-xxs">
                  {group.items.map((item) => (
                    <SettingsSidebarItemControl item={item} key={item.id} />
                  ))}
                </div>
              </div>
            ))
          )}
        </nav>
      </ScrollArea>
    </aside>
  );
});
