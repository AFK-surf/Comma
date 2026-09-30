import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { SettingsPanel } from "../settings-panel";
import { useLatestCallback } from "../settings-panel/settingsIdentity";
import {
  SettingsSidebar,
  type SettingsSidebarGroup,
  type SettingsSidebarLayout,
  type SettingsSidebarSearchGroup,
} from "../settings-sidebar";
import { cx } from "../utils";
import { SettingsCategoryIconView } from "./SettingsCategoryIconView";
import { SettingsDetailView } from "./SettingsDetailView";
import type {
  SettingsCategoryDefinition,
  SettingsCategoryDetail,
  SettingsRegistry,
  SettingsSearchResult,
} from "./settingsRegistry";

export interface SettingsPageProps {
  activeCategoryId?: string;
  ariaLabel?: string;
  className?: string;
  contentAriaLabel?: string;
  defaultActiveCategoryId?: string;
  emptySearchDescription?: string;
  emptySearchTitle?: string;
  onActiveCategoryChange?: (categoryId: string) => void;
  /** Called when the page moves its categories between the rail and a tab row. */
  onLayoutChange?: (layout: SettingsSidebarLayout) => void;
  onSearchQueryChange?: (query: string) => void;
  registry: SettingsRegistry;
  searchAriaLabel: string;
  searchPlaceholder: string;
  searchQuery?: string;
}

/**
 * Below this the card is too narrow to carry a 286px rail beside a legible
 * content column, so the categories move to a row above the content. The
 * stylesheet reads the resulting `data-layout` rather than a media query: the
 * card can be narrower than the window that holds it.
 */
const settingsTabsMaxWidth = 700;

const categoryTitle = (category: SettingsCategoryDefinition) =>
  category.title ?? category.label;

function useSettingsLayout(pageRef: { current: HTMLDivElement | null }) {
  const [layout, setLayout] = useState<SettingsSidebarLayout>("rail");

  useLayoutEffect(() => {
    const element = pageRef.current;
    if (!element) return undefined;

    const observer = new ResizeObserver(([entry]) => {
      const width = entry?.contentRect.width ?? 0;
      // A zero width is a card that has not been measured, not a narrow one.
      setLayout(width > 0 && width <= settingsTabsMaxWidth ? "tabs" : "rail");
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [pageRef]);

  return layout;
}

/**
 * A second-level page takes the content column outright. No transition and no
 * leaving snapshot: this is navigation inside a panel the reader already has
 * open, so the cheapest correct answer is to swap what is mounted.
 */
const renderDetail = (detail?: SettingsCategoryDetail) =>
  detail ? (
    <SettingsDetailView
      id={detail.id}
      title={detail.title}
      backLabel={detail.backLabel}
      onBack={detail.onBack}
      {...(detail.description !== undefined ? { description: detail.description } : {})}
      {...(detail.actions !== undefined ? { actions: detail.actions } : {})}
      {...(detail.sections !== undefined ? { sections: detail.sections } : {})}
      {...(detail.onSubmit !== undefined ? { onSubmit: detail.onSubmit } : {})}
    >
      {detail.content}
    </SettingsDetailView>
  ) : null;

const noSearchGroups: SettingsSidebarSearchGroup[] = [];

const normalizeSearchText = (value: string) =>
  value.normalize("NFKD").toLocaleLowerCase();

const searchResultContext = (result: SettingsSearchResult, query: string) => {
  const tokens = normalizeSearchText(query).trim().split(/\s+/).filter(Boolean);
  const candidates = [
    result.item.description,
    ...Array.from(result.item.keywords ?? []),
  ].filter((value): value is string => Boolean(value));

  return (
    candidates.find((candidate) => {
      const normalizedCandidate = normalizeSearchText(candidate);
      return tokens.some((token) => normalizedCandidate.includes(token));
    }) ?? result.item.description
  );
};

export const SettingsPage = ({
  activeCategoryId,
  ariaLabel = "Settings",
  className,
  contentAriaLabel = "Settings content",
  defaultActiveCategoryId,
  emptySearchDescription,
  emptySearchTitle = "No settings found",
  onActiveCategoryChange,
  onLayoutChange,
  onSearchQueryChange,
  registry,
  searchAriaLabel,
  searchPlaceholder,
  searchQuery,
}: SettingsPageProps) => {
  const fallbackCategoryId =
    defaultActiveCategoryId ?? registry.categories[0]?.id ?? "";
  const [localActiveCategoryId, setLocalActiveCategoryId] =
    useState(fallbackCategoryId);
  const [activeItemId, setActiveItemId] = useState<string>();
  const [localSearchQuery, setLocalSearchQuery] = useState("");
  const pageRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLElement | null>(null);
  const layout = useSettingsLayout(pageRef);
  // Before paint, so a host's own controls move with the categories.
  useLayoutEffect(() => {
    onLayoutChange?.(layout);
  }, [layout, onLayoutChange]);
  const resolvedActiveCategoryId = activeCategoryId ?? localActiveCategoryId;
  const activeCategory =
    registry.getCategory(resolvedActiveCategoryId) ??
    registry.getCategory(fallbackCategoryId);
  const resolvedSearchQuery = searchQuery ?? localSearchQuery;
  const normalizedSearchQuery = resolvedSearchQuery.trim();
  const results = useMemo(
    () => registry.search(normalizedSearchQuery),
    [normalizedSearchQuery, registry]
  );

  /*
   * Controls in the content routinely remove themselves as a result of being
   * pressed: a second-level page replaces the rows, a retry swaps itself for a
   * loading state, a button jumps to another category. Focus then sits on no
   * element, and the modal's React Aria focus scope answers that by focusing
   * the first tabbable thing it can find — the sidebar's "Search settings"
   * box, which visibly lights up in a pane the reader was not working in.
   *
   * The rule that fixes all of it: if the last thing the reader touched was
   * inside the content region, focus belongs in the content region. Deliberate
   * moves out of it — clicking a category in the rail, the close button, the
   * search box itself — start from a touch outside content and are left alone.
   * Tab navigation also clears this intent so the browser can move focus.
   */
  const touchedContent = useRef(false);
  useEffect(() => {
    const root = pageRef.current;
    if (!root) return undefined;
    const noteIntent = (event: Event) => {
      const target = event.target;
      touchedContent.current =
        !(event instanceof KeyboardEvent && event.key === "Tab") &&
        target instanceof Node &&
        !!contentRef.current?.contains(target);
    };
    const keepFocusInContent = (event: FocusEvent) => {
      const content = contentRef.current;
      const target = event.target;
      if (!content || !(target instanceof Node)) return;
      if (content.contains(target) || !touchedContent.current) return;
      content.focus();
    };
    root.addEventListener("pointerdown", noteIntent, true);
    root.addEventListener("keydown", noteIntent, true);
    root.addEventListener("focusin", keepFocusInContent, true);
    return () => {
      root.removeEventListener("pointerdown", noteIntent, true);
      root.removeEventListener("keydown", noteIntent, true);
      root.removeEventListener("focusin", keepFocusInContent, true);
    };
  }, []);

  const clearSearch = () => {
    if (searchQuery === undefined) setLocalSearchQuery("");
    onSearchQueryChange?.("");
  };

  // The sidebar renders again only when its categories or the search change,
  // not on every change inside a category, so its callbacks stay stable.
  const activateCategory = useLatestCallback((categoryId: string, itemId?: string) => {
    clearSearch();
    setActiveItemId(itemId);
    if (activeCategoryId === undefined) {
      setLocalActiveCategoryId(categoryId);
    }
    onActiveCategoryChange?.(categoryId);
  });

  const sidebarCategories = JSON.stringify(
    registry.groups.map((group) => ({
      id: group.id,
      label: group.label,
      categories: group.categories.map(({ icon, id, label }) => ({ icon, id, label })),
    }))
  );
  const selectedCategoryId = activeCategory?.id;
  const groups = useMemo(
    (): SettingsSidebarGroup[] =>
      (
        JSON.parse(sidebarCategories) as {
          categories: Pick<SettingsCategoryDefinition, "icon" | "id" | "label">[];
          id: string;
          label?: string;
        }[]
      ).map((group) => ({
        id: group.id,
        ...(group.label !== undefined ? { label: group.label } : {}),
        items: group.categories.map((category) => ({
          icon: <SettingsCategoryIconView className="size-4.5" icon={category.icon} />,
          id: category.id,
          label: category.label,
          onPress: () => activateCategory(category.id),
          selected: category.id === selectedCategoryId,
        })),
      })),
    [activateCategory, selectedCategoryId, sidebarCategories]
  );

  const searchGroups: SettingsSidebarSearchGroup[] = registry.groups.flatMap((group) =>
    group.categories.flatMap((category) =>
      category.sections.flatMap((section) => {
        const sectionResults = results.filter(
          (result) =>
            result.category.id === category.id && result.section.id === section.id
        );
        if (sectionResults.length === 0) return [];

        // An untitled section (a lone card under the page title) is labelled
        // by its category alone rather than a dangling separator.
        const label = [category.label, section.title]
          .filter(Boolean)
          .filter((part, index, parts) => index === 0 || part !== parts[index - 1])
          .join(" · ");
        return [
          {
            id: `${category.id}:${section.id}`,
            label,
            items: sectionResults.map((result) => {
              const context = searchResultContext(result, normalizedSearchQuery);
              return {
                id: result.item.id,
                title: result.item.title,
                ...(context ? { context } : {}),
                onPress: () => activateCategory(result.category.id, result.item.id),
              };
            }),
          },
        ];
      })
    )
  );

  const handleSearchQueryChange = useLatestCallback((nextQuery: string) => {
    setActiveItemId(undefined);
    if (searchQuery === undefined) setLocalSearchQuery(nextQuery);
    onSearchQueryChange?.(nextQuery);
  });

  return (
    <div
      aria-label={ariaLabel}
      className={cx(
        "comma-settings-page flex size-full min-h-0 min-w-0 [--comma-overlay-safe-top:2.75rem]",
        layout === "tabs" && "flex-col",
        className
      )}
      data-layout={layout}
      data-slot="settings-page"
      ref={pageRef}
    >
      <SettingsSidebar
        ariaLabel={ariaLabel}
        groups={groups}
        layout={layout}
        onSearchChange={handleSearchQueryChange}
        searchAriaLabel={searchAriaLabel}
        {...(emptySearchDescription !== undefined
          ? { searchEmptyDescription: emptySearchDescription }
          : {})}
        searchEmptyTitle={emptySearchTitle}
        searchGroups={searchGroups.length > 0 ? searchGroups : noSearchGroups}
        searchPlaceholder={searchPlaceholder}
        searchValue={resolvedSearchQuery}
      />
      <section
        aria-label={contentAriaLabel}
        className="comma-settings-content relative min-h-0 min-w-0 flex-1 outline-none"
        data-slot="settings-content"
        ref={contentRef}
        tabIndex={-1}
      >
        {activeCategory?.content !== undefined ? (
          <div
            className="size-full min-h-0 min-w-0 overflow-y-auto"
            data-slot="settings-category-content"
          >
            {activeCategory.content}
          </div>
        ) : (
          (renderDetail(activeCategory?.detail) ?? (
            <SettingsPanel
              className="min-w-0"
              sections={Array.from(activeCategory?.sections ?? [])}
              surface="embedded"
              title={activeCategory ? categoryTitle(activeCategory) : ""}
              {...(activeCategory?.titleAction !== undefined
                ? { titleAction: activeCategory.titleAction }
                : {})}
              {...(activeItemId !== undefined ? { activeItemId } : {})}
            />
          ))
        )}
        {activeCategory?.overlay}
      </section>
    </div>
  );
};
