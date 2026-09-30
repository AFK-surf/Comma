import type { ReactNode } from "react";
import type { SettingsPanelItem, SettingsPanelSection } from "../settings-panel";

export type SettingsCategoryIcon =
  | "archived-tasks"
  | "shared-tasks"
  | "labels"
  | "general"
  | "notifications"
  | "recommendations"
  | "channels"
  | "inbound-api"
  | "voice"
  | "profile"
  | "appearance"
  | "meeting"
  | "browser"
  | "keyboard-shortcuts"
  | "usage-billing"
  | "devices"
  | "computer-use"
  | "models-api-keys"
  | "debug";

/**
 * A second-level page opened from inside a category. While one is set, the
 * category's own rows step aside for it — no dialog is stacked over Settings.
 */
export interface SettingsCategoryDetail {
  id: string;
  title: string;
  description?: ReactNode;
  backLabel: string;
  onBack: () => void;
  actions?: ReactNode;
  onSubmit?: () => void;
  /** Rendered in the settings card grammar, above `content`. */
  sections?: readonly SettingsPanelSection[];
  content?: ReactNode;
}

export interface SettingsCategoryDefinition {
  id: string;
  icon: SettingsCategoryIcon;
  keywords?: readonly string[];
  label: string;
  sections: readonly SettingsPanelSection[];
  title?: string;
  /** Optional control rendered opposite the category title (space-between). */
  titleAction?: ReactNode;
  /**
   * A category that is a page of its own rather than a list of setting rows:
   * rendered in place of the panel (title, sections and cards), owning its
   * layout end to end. `sections` still feeds search and may be empty.
   */
  content?: ReactNode;
  /** Second-level page shown in place of this category's rows. */
  detail?: SettingsCategoryDetail;
  /**
   * Mounted alongside whichever view is showing, for a confirmation the reader
   * must answer before anything else — a deletion, not a form. A form belongs
   * in `detail`, which gives it the column instead of stacking a window on the
   * window Settings already is.
   */
  overlay?: ReactNode;
}

export interface SettingsCategoryGroupDefinition {
  categories: readonly SettingsCategoryDefinition[];
  id: string;
  label?: string;
}

export interface SettingsRegistryDefinition {
  groups: readonly SettingsCategoryGroupDefinition[];
}

export interface SettingsSearchResult {
  category: SettingsCategoryDefinition;
  group: SettingsCategoryGroupDefinition;
  item: SettingsPanelItem;
  section: SettingsPanelSection;
}

export interface SettingsRegistry {
  categories: readonly SettingsCategoryDefinition[];
  getCategory: (id: string) => SettingsCategoryDefinition | undefined;
  groups: readonly SettingsCategoryGroupDefinition[];
  search: (query: string) => SettingsSearchResult[];
}

interface SearchEntry extends SettingsSearchResult {
  descriptionText: string;
  searchableText: string;
  titleText: string;
}

const normalizeSearchText = (value: string) =>
  value.normalize("NFKD").toLocaleLowerCase().replace(/\s+/g, " ").trim();

const assertUniqueId = (ids: Set<string>, id: string, kind: string) => {
  if (!id.trim()) {
    throw new Error(`Settings ${kind} id must not be empty.`);
  }
  if (ids.has(id)) {
    throw new Error(`Duplicate settings ${kind} id: "${id}".`);
  }
  ids.add(id);
};

const scoreEntry = (entry: SearchEntry, normalizedQuery: string) => {
  if (entry.titleText === normalizedQuery) return 0;
  if (entry.titleText.startsWith(normalizedQuery)) return 1;
  if (entry.titleText.includes(normalizedQuery)) return 2;
  if (entry.descriptionText.includes(normalizedQuery)) return 3;
  return 4;
};

export const createSettingsRegistry = ({
  groups,
}: SettingsRegistryDefinition): SettingsRegistry => {
  const groupIds = new Set<string>();
  const categoryIds = new Set<string>();
  const sectionIds = new Set<string>();
  const itemIds = new Set<string>();
  const categories: SettingsCategoryDefinition[] = [];
  const searchEntries: SearchEntry[] = [];

  for (const group of groups) {
    assertUniqueId(groupIds, group.id, "group");

    for (const category of group.categories) {
      assertUniqueId(categoryIds, category.id, "category");
      categories.push(category);

      for (const section of category.sections) {
        assertUniqueId(sectionIds, section.id, "section");

        for (const item of section.items) {
          assertUniqueId(itemIds, item.id, "item");
          const titleText = normalizeSearchText(item.title);
          const descriptionText = normalizeSearchText(item.description ?? "");
          const searchableText = normalizeSearchText(
            [
              group.label,
              category.label,
              category.title,
              ...Array.from(category.keywords ?? []),
              section.title,
              item.title,
              item.description,
              item.integration?.status.label,
              item.integration?.note,
              ...(item.integration?.details.flatMap((detail) => [
                detail.label,
                detail.value,
                detail.actionLabel,
              ]) ?? []),
              ...Array.from(item.keywords ?? []),
            ]
              .filter((value): value is string => Boolean(value))
              .join(" ")
          );

          searchEntries.push({
            category,
            descriptionText,
            group,
            item,
            searchableText,
            section,
            titleText,
          });
        }
      }
    }
  }

  const categoryById = new Map(
    categories.map((category) => [category.id, category] as const)
  );

  return {
    categories,
    getCategory: (id) => categoryById.get(id),
    groups,
    search: (query) => {
      const normalizedQuery = normalizeSearchText(query);
      if (!normalizedQuery) return [];

      const tokens = normalizedQuery.split(" ");
      return searchEntries
        .filter((entry) =>
          tokens.every((token) => entry.searchableText.includes(token))
        )
        .map((entry, index) => ({
          entry,
          index,
          score: scoreEntry(entry, normalizedQuery),
        }))
        .toSorted((left, right) => left.score - right.score || left.index - right.index)
        .map(({ entry }) => ({
          category: entry.category,
          group: entry.group,
          item: entry.item,
          section: entry.section,
        }));
    },
  };
};
