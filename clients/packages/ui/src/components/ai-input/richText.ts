import type { ReactNode } from "react";

export interface AiInputRichTextSegment {
  type: "text";
  text: string;
}

export interface AiInputRichTokenSegment {
  type: "token";
  /** Stable for the lifetime of one token occurrence in the editor. */
  instanceId: string;
  menuId: string;
  itemId: string;
  trigger: string;
  label: string;
  /** Optional detail shown when the token is hovered or focused. */
  description?: string;
  /**
   * Serialized `<svg>`/`<img>` markup for the pill's glyph, captured from the
   * menu's own rendered option on selection. Sanitized again at render time;
   * the glyph is tinted to the token's text color.
   */
  iconMarkup?: string;
  /** Text sent through the backwards-compatible string submission API. */
  plainText: string;
  data?: unknown;
}

export type AiInputRichSegment = AiInputRichTextSegment | AiInputRichTokenSegment;

export interface AiInputRichValue {
  segments: AiInputRichSegment[];
  plainText: string;
  tokens: AiInputRichTokenSegment[];
}

export interface AiInputMenuItem {
  /** Inline descriptions follow the label; trailing descriptions align to the row end. */
  descriptionPlacement?: "inline" | "trailing";
  id: string;
  label: string;
  description?: string;
  searchText?: string;
  keywords?: readonly string[];
  /** Optional visual shown in the suggestion menu. */
  icon?: ReactNode;
  /** Defaults to the item label. */
  tokenLabel?: string;
  /** Defaults to `${trigger}${id}`. */
  plainText?: string;
  /** Insert editable text instead of an atomic mention token. */
  insertText?: string;
  data?: unknown;
  disabled?: boolean;
  /**
   * Selecting an action row runs this instead of inserting a token. The
   * editor removes the trigger text and closes the menu first, so the action
   * (e.g. opening a file picker) never races the caret it was invoked from.
   */
  action?: () => void;
  /** Retry actions keep the current trigger and menu visible. */
  keepMenuOpen?: boolean;
  /**
   * Set on the trailing "View more" row the filter appends to a group with
   * `browse`: selecting it (Enter, click, or ArrowRight) opens that group's
   * browse panel in place of the list instead of inserting a token. Product
   * code never sets this; the filter does.
   */
  browseGroupId?: string;
}

/**
 * A second level behind a group: the whole source, searchable, arranged in
 * its own sections. The menu lists the group's first `limit` matches and a
 * trailing "View more" row that steps into this.
 */
export interface AiInputMenuBrowse {
  onQueryChange?: ((query: string | null) => void) | undefined;
  /** The next page, asked for as the reader scrolls or arrows past the end. */
  onLoadMore?: (() => void) | undefined;
  loadingMore?: boolean | undefined;
  status?: "ready" | "loading" | undefined;
  error?: string | undefined;
  onRetry?: (() => void) | undefined;
  retryLabel?: string | undefined;
  prefiltered?: boolean | undefined;
  /** The trailing row's label. */
  label: string;
  /** Names the panel to assistive tech. */
  title: string;
  searchPlaceholder: string;
  /** Centered when the source has nothing at all. */
  emptyLabel: string;
  /** Centered when a search matches nothing. */
  noResultsLabel: string;
  /**
   * Everything the panel can show, under the sections it shows them in. The
   * group's own `items` stay the menu's short list; these are the same rows
   * arranged for browsing.
   */
  groups: readonly AiInputMenuGroup[];
}

export interface AiInputMenuGroup {
  prefiltered?: boolean | undefined;
  id: string;
  label?: string;
  items: readonly AiInputMenuItem[];
  /**
   * "loading" keeps the section visible with a searching row while its
   * source is still indexing; filtering never drops a loading section.
   */
  status?: "ready" | "loading";
  /**
   * Rows the menu shows for this group at most; the rest stay reachable
   * through `browse`. Matches are ranked before the cap applies, so a query
   * still finds a row past it.
   */
  limit?: number;
  browse?: AiInputMenuBrowse;
}

export interface AiInputMenuContext {
  trigger: string;
  query: string;
  textBeforeTrigger: string;
  plainText: string;
}

/**
 * A trigger-driven rich-text menu. The UI package intentionally owns only the
 * editor contract; product packages provide plugin/skill data and submission
 * representations through registrations.
 */
export interface AiInputMenuRegistration {
  onQueryChange?: ((query: string | null) => void) | undefined;
  id: string;
  trigger: string;
  label: string;
  groups: readonly AiInputMenuGroup[];
  maxItems?: number;
  shouldOpen?: (context: AiInputMenuContext) => boolean;
}

export interface AiInputMenuMatch {
  registration: AiInputMenuRegistration;
  query: string;
  start: number;
}

const defaultMaxItems = 8;

/**
 * Fullwidth variants a CJK input method may commit in place of the ASCII
 * trigger. They open the same menu, and selecting an item replaces the
 * fullwidth character along with the query.
 */
const triggerFallbacks: Record<string, readonly string[]> = {
  "/": ["／"],
  "@": ["＠"],
};

export function findAiInputMenuMatch(
  textBeforeCaret: string,
  registrations: readonly AiInputMenuRegistration[],
  plainText = textBeforeCaret
): AiInputMenuMatch | null {
  let closest: AiInputMenuMatch | null = null;

  registrations.forEach((registration) => {
    if (!registration.trigger) return;
    const aliases = [
      registration.trigger,
      ...(triggerFallbacks[registration.trigger] ?? []),
    ];

    aliases.forEach((alias) => {
      const start = textBeforeCaret.lastIndexOf(alias);
      if (start < 0 || (start > 0 && !/\s/u.test(textBeforeCaret[start - 1] ?? ""))) {
        return;
      }

      const query = textBeforeCaret.slice(start + alias.length);
      if (/\s/u.test(query)) return;

      const context: AiInputMenuContext = {
        trigger: registration.trigger,
        query,
        textBeforeTrigger: textBeforeCaret.slice(0, start),
        plainText,
      };
      if (registration.shouldOpen && !registration.shouldOpen(context)) return;

      if (!closest || start > closest.start) {
        closest = { registration, query, start };
      }
    });
  });

  return closest;
}

export function filterAiInputMenuGroups(
  registration: AiInputMenuRegistration,
  query: string
) {
  const maxItems = registration.maxItems ?? defaultMaxItems;
  let remaining = maxItems;

  return registration.groups.flatMap((group) => {
    // A loading section stays visible with zero items so the panel can show
    // its searching state; a settled section with no matches disappears.
    if (remaining <= 0) {
      return group.status === "loading" ? [{ ...group, items: [] }] : [];
    }

    const items = (
      group.prefiltered ? group.items : filterAiInputMenuItems(group.items, query)
    ).slice(0, Math.min(remaining, group.limit ?? Number.POSITIVE_INFINITY));
    remaining -= items.length;

    // The browse row is the door to the whole source, so it stays once the
    // source has settled, matches or not: a query that finds nothing in the
    // short list can still open the panel and carry on searching there.
    if (group.browse && group.status !== "loading") {
      items.push(browseMenuItem(group.id, group.browse));
      remaining -= 1;
    }
    return items.length > 0 || group.status === "loading" ? [{ ...group, items }] : [];
  });
}

/** The id of the "View more" row the filter appends to a group with `browse`. */
export const aiInputMenuBrowseItemId = (groupId: string) => `${groupId}:browse`;

function browseMenuItem(groupId: string, browse: AiInputMenuBrowse): AiInputMenuItem {
  return {
    id: aiInputMenuBrowseItemId(groupId),
    label: browse.label,
    browseGroupId: groupId,
  };
}

/**
 * The rows a query keeps, best match first: names before descriptions and
 * keywords, and source order within a rank so a recency-ordered source
 * stays recency-ordered among equals.
 */
export function filterAiInputMenuItems(
  items: readonly AiInputMenuItem[],
  query: string
): AiInputMenuItem[] {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  return items
    .filter((item) => !item.disabled)
    .map((item, index) => ({ item, index, rank: itemRank(item, normalizedQuery) }))
    .filter(
      (entry): entry is { item: AiInputMenuItem; index: number; rank: number } =>
        entry.rank !== undefined
    )
    .toSorted((a, b) => (a.rank === b.rank ? a.index - b.index : a.rank - b.rank))
    .map((entry) => entry.item);
}

export function createAiInputRichValue(
  segments: readonly AiInputRichSegment[]
): AiInputRichValue {
  const normalizedSegments = coalesceTextSegments(segments);
  const tokens = normalizedSegments.filter(
    (segment): segment is AiInputRichTokenSegment => segment.type === "token"
  );

  return {
    segments: normalizedSegments,
    plainText: normalizedSegments
      .map((segment) => (segment.type === "token" ? segment.plainText : segment.text))
      .join(""),
    tokens,
  };
}

export function createPlainAiInputRichValue(text: string): AiInputRichValue {
  return createAiInputRichValue(text ? [{ type: "text", text }] : []);
}

function coalesceTextSegments(segments: readonly AiInputRichSegment[]) {
  const result: AiInputRichSegment[] = [];

  segments.forEach((segment) => {
    if (segment.type === "text" && !segment.text) return;
    const previous = result.at(-1);
    if (segment.type === "text" && previous?.type === "text") {
      previous.text += segment.text;
      return;
    }
    result.push(segment.type === "text" ? { ...segment } : segment);
  });

  return result;
}

function itemRank(item: AiInputMenuItem, query: string) {
  if (!query) return 0;

  const primary = [item.searchText, item.label, item.id]
    .filter(Boolean)
    .map((value) => value!.toLocaleLowerCase());
  if (primary.some((value) => value.startsWith(query))) return 0;
  if (primary.some((value) => value.includes(query))) return 1;

  const secondary = [item.description, ...(item.keywords ?? [])]
    .filter(Boolean)
    .map((value) => value!.toLocaleLowerCase());
  return secondary.some((value) => value.includes(query)) ? 2 : undefined;
}
