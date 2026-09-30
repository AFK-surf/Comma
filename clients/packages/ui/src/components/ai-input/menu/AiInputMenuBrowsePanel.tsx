/* oxlint-disable jsx-a11y/prefer-tag-over-role -- the filter field is a combobox over a listbox of option buttons, the same ARIA the list level keeps. */
import {
  startTransition,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
  type UIEvent,
} from "react";
import { ChevronLeftSmallIcon } from "../../icons";
import { InputBase } from "../../input/InputBase";
import { menuFilterFieldClasses } from "../../menu/styles";
import { ScrollArea, ScrollAreaLoadMore } from "../../scroll-area";
import { isImeKeyEvent } from "../../utils";
import { useAiInputMenuNavigation } from "./useAiInputMenuNavigation";
import {
  AiInputMenuSearchingRow,
  AiInputMenuSearchingText,
} from "./AiInputMenuSearchingText";
import {
  filterAiInputMenuItems,
  type AiInputMenuBrowse,
  type AiInputMenuGroup,
  type AiInputMenuItem,
} from "../richText";
import {
  AI_INPUT_MENU_MAX_HEIGHT_PX,
  aiInputMenuBrowse,
  aiInputMenuBrowseBack,
  aiInputMenuBrowseBody,
  aiInputMenuBrowseState,
  aiInputMenuItem,
  aiInputMenuItemDescription,
  aiInputMenuItemIcon,
  aiInputMenuItemLabel,
  aiInputMenuItemInlineLabel,
  aiInputMenuItemInlineDescription,
  aiInputMenuScrollContent,
  aiInputMenuSection,
  aiInputMenuSectionLabel,
} from "../styles";

/**
 * Rows committed per scroll step. Smaller than the list level's chunk: the
 * browse panel is where a whole source lives, so the first paint stays
 * light and the rest arrives as the reader scrolls toward it.
 */
const RENDER_CHUNK = 24;
/** Distance from the bottom edge (px) at which the next chunk is committed. */
const RENDER_AHEAD_PX = 96;

export interface AiInputMenuBrowsePanelProps {
  backLabel: string;
  browse: AiInputMenuBrowse;
  /** False for the exit ghost, which must never take focus. */
  focusOnMount: boolean;
  /** The group behind the panel; its status is the source's. */
  group: AiInputMenuGroup;
  /** The trigger query typed so far, carried into the search. */
  initialQuery: string;
  /** Id of the listbox, which the editor's `aria-controls` also names. */
  listId: string;
  onBack: () => void;
  /** Focus left the search field for somewhere outside the panel. */
  onBlur: (relatedTarget: Element | null) => void;
  onSelectItem: (item: AiInputMenuItem) => void;
  optionId: (itemId: string | undefined) => string | undefined;
  searchingLabel: string;
}

interface RenderedSection {
  group: AiInputMenuGroup;
  startIndex: number;
  visible: readonly AiInputMenuItem[];
}

export const AiInputMenuBrowsePanel = ({
  backLabel,
  browse,
  focusOnMount,
  group,
  initialQuery,
  listId,
  onBack,
  onBlur,
  onSelectItem,
  optionId,
  searchingLabel,
}: AiInputMenuBrowsePanelProps) => {
  const inputRef = useRef<HTMLInputElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const [query, setQuery] = useState(initialQuery);
  // Filtering a whole source is deferred: keystrokes land in the field at
  // once, the rows follow, and the gap between the two — real only for a
  // source large enough to have one — reads as searching.
  const deferredQuery = useDeferredValue(query);
  const searching = deferredQuery !== query;
  const queryChanged = browse.onQueryChange;
  useEffect(() => {
    if (!focusOnMount) return;
    queryChanged?.(query);
    return () => queryChanged?.(null);
  }, [focusOnMount, query, queryChanged]);
  const [activeIndex, setActiveIndex] = useState(0);
  const [renderLimit, setRenderLimit] = useState(RENDER_CHUNK);
  const [committing, setCommitting] = useState(false);
  const previousQueryRef = useRef(deferredQuery);

  // A new query starts from the top, synchronously, so the old selection
  // and window never paint under the new rows.
  if (previousQueryRef.current !== deferredQuery) {
    previousQueryRef.current = deferredQuery;
    if (activeIndex !== 0) setActiveIndex(0);
    if (renderLimit !== RENDER_CHUNK) setRenderLimit(RENDER_CHUNK);
  }

  const sections = useMemo(
    () =>
      browse.groups.flatMap((section) => {
        const items = browse.prefiltered
          ? [...section.items]
          : filterAiInputMenuItems(section.items, deferredQuery);
        return items.length > 0 ? [{ ...section, items }] : [];
      }),
    [browse.groups, browse.prefiltered, deferredQuery]
  );
  const items = useMemo(() => sections.flatMap((section) => section.items), [sections]);
  // A later page can add rows to an earlier folder. Keep keyboard selection
  // attached to its file instead of selecting whichever row inherits its index.
  const previousItemsRef = useRef({ items, query: deferredQuery });
  if (previousItemsRef.current.items !== items) {
    const previous = previousItemsRef.current;
    previousItemsRef.current = { items, query: deferredQuery };
    if (previous.query === deferredQuery) {
      const selectedId = previous.items[activeIndex]?.id;
      const nextIndex = selectedId
        ? items.findIndex((item) => item.id === selectedId)
        : -1;
      const next =
        nextIndex >= 0
          ? nextIndex
          : Math.min(activeIndex, Math.max(0, items.length - 1));
      if (next !== activeIndex) setActiveIndex(next);
    }
  }
  const sourceEmpty = browse.groups.every((section) => section.items.length === 0);

  const effectiveLimit = Math.max(
    renderLimit,
    Math.ceil((activeIndex + 1) / RENDER_CHUNK) * RENDER_CHUNK
  );
  const renderedSections = useMemo(() => {
    let taken = 0;
    return sections.flatMap((section): RenderedSection[] => {
      if (taken >= effectiveLimit) return [];
      const visible = section.items.slice(0, effectiveLimit - taken);
      const startIndex = taken;
      taken += visible.length;
      return [{ group: section, startIndex, visible }];
    });
  }, [effectiveLimit, sections]);
  const renderedCount = renderedSections.reduce(
    (sum, section) => sum + section.visible.length,
    0
  );

  useEffect(() => {
    if (focusOnMount) inputRef.current?.focus();
  }, [focusOnMount]);

  const handlePointerMove = useAiInputMenuNavigation(
    optionId(items[activeIndex]?.id),
    items,
    setActiveIndex,
    focusOnMount
  );

  const handleScroll = (event: UIEvent<HTMLDivElement>) => {
    if (committing) return;
    const viewport = event.currentTarget;
    const remaining =
      viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
    // Past the last rendered row the next page is the load trigger's to ask for.
    if (remaining > RENDER_AHEAD_PX || renderedCount >= items.length) return;
    // The next chunk lands as a transition: the rows already on screen stay
    // responsive, and the trailing row shines only for as long as the
    // commit actually takes.
    setCommitting(true);
    startTransition(() => {
      setRenderLimit(effectiveLimit + RENDER_CHUNK);
      setCommitting(false);
    });
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const input = event.currentTarget;
    if (isImeKeyEvent(event.nativeEvent)) return;

    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (
        event.key === "ArrowDown" &&
        activeIndex >= items.length - 1 &&
        browse.onLoadMore
      ) {
        if (!browse.loadingMore) browse.onLoadMore();
        return;
      }
      if (items.length === 0) return;
      const delta = event.key === "ArrowDown" ? 1 : -1;
      setActiveIndex((current) => (current + delta + items.length) % items.length);
      return;
    }

    if (event.key === "Enter" || event.key === "Tab") {
      event.preventDefault();
      const item = items[activeIndex] ?? items[0];
      if (item) onSelectItem(item);
      return;
    }

    // Escape, a Backspace on an empty field, and ArrowLeft from the field's
    // start all step back to the list: the same three ways out a submenu has.
    if (
      event.key === "Escape" ||
      (event.key === "Backspace" && query === "") ||
      (event.key === "ArrowLeft" &&
        input.selectionStart === 0 &&
        input.selectionEnd === 0)
    ) {
      event.preventDefault();
      event.stopPropagation();
      onBack();
    }
  };

  const handleBlur = (event: FocusEvent<HTMLInputElement>) => {
    const next = event.relatedTarget instanceof Element ? event.relatedTarget : null;
    if (next && rootRef.current?.contains(next)) return;
    onBlur(next);
  };

  const loading = (browse.status ?? group.status) === "loading";
  const activeOptionId = optionId(items[activeIndex]?.id);

  return (
    <div
      className={aiInputMenuBrowse}
      data-testid="ai-input-menu-browse"
      ref={rootRef}
      style={{ height: AI_INPUT_MENU_MAX_HEIGHT_PX }}
    >
      {/* oxlint-disable-next-line jsx-a11y/interactive-supports-focus -- InputBase renders an <input>, focusable by nature. */}
      <InputBase
        aria-activedescendant={activeOptionId}
        aria-autocomplete="list"
        aria-controls={listId}
        aria-expanded="true"
        aria-label={browse.title}
        autoComplete="off"
        data-testid="ai-input-menu-browse-search"
        iconClassName="pointer-events-auto"
        leadingIcon={
          <button
            aria-label={backLabel}
            className={aiInputMenuBrowseBack}
            onClick={onBack}
            onMouseDown={(event) => event.preventDefault()}
            type="button"
          >
            <ChevronLeftSmallIcon className="comma-icon-press-back" />
          </button>
        }
        onBlur={handleBlur}
        onChange={(event) => setQuery(event.currentTarget.value)}
        onKeyDown={handleKeyDown}
        placeholder={browse.searchPlaceholder}
        ref={inputRef}
        role="combobox"
        size="sm"
        spellCheck={false}
        suppressFocusRing
        type="text"
        value={query}
        wrapperClassName={menuFilterFieldClasses}
      />
      <div className={aiInputMenuBrowseBody}>
        {browse.error ? (
          <div className={aiInputMenuBrowseState} role="status">
            <span>{browse.error}</span>
            <button type="button" onClick={browse.onRetry}>
              {browse.retryLabel}
            </button>
          </div>
        ) : null}
        {browse.error && sourceEmpty ? null : loading || searching ? (
          <div
            className={aiInputMenuBrowseState}
            data-testid="ai-input-menu-browse-searching"
            key="searching"
          >
            <AiInputMenuSearchingText label={searchingLabel} />
          </div>
        ) : sourceEmpty && !browse.onLoadMore ? (
          <div
            className={aiInputMenuBrowseState}
            data-testid={
              query && browse.prefiltered
                ? "ai-input-menu-browse-no-results"
                : "ai-input-menu-browse-empty"
            }
            key="empty"
          >
            <span className="min-w-0 truncate">
              {query ? browse.noResultsLabel : browse.emptyLabel}
            </span>
          </div>
        ) : items.length === 0 && !browse.onLoadMore ? (
          <div
            className={aiInputMenuBrowseState}
            data-testid="ai-input-menu-browse-no-results"
            key="no-results"
          >
            <span className="min-w-0 truncate">{browse.noResultsLabel}</span>
          </div>
        ) : (
          <ScrollArea
            className="min-h-0 w-full flex-1"
            contentClassName={aiInputMenuScrollContent}
            onScroll={handleScroll}
            orientation="vertical"
            viewportClassName="h-full"
            viewportProps={{
              "aria-label": browse.title,
              id: listId,
              role: "listbox",
              tabIndex: -1,
            }}
          >
            {renderedSections.map(({ group: section, startIndex, visible }) => (
              <div className={aiInputMenuSection} key={section.id} role="group">
                {section.label ? (
                  <div className={aiInputMenuSectionLabel}>{section.label}</div>
                ) : null}
                {visible.map((item, index) => {
                  const itemIndex = startIndex + index;
                  return (
                    <button
                      aria-selected={itemIndex === activeIndex}
                      className={aiInputMenuItem}
                      data-no-press-feedback=""
                      id={optionId(item.id)}
                      key={item.id}
                      onMouseDown={(event) => {
                        event.preventDefault();
                        onSelectItem(item);
                      }}
                      onPointerMove={(event) => handlePointerMove(event, itemIndex)}
                      role="option"
                      type="button"
                    >
                      {item.icon ? (
                        <span
                          aria-hidden
                          className={aiInputMenuItemIcon}
                          data-slot="ai-input-menu-item-icon"
                        >
                          {item.icon}
                        </span>
                      ) : null}
                      <span
                        className={
                          item.descriptionPlacement === "inline"
                            ? aiInputMenuItemInlineLabel
                            : aiInputMenuItemLabel
                        }
                      >
                        {item.label}
                      </span>
                      {item.description ? (
                        <span
                          className={
                            item.descriptionPlacement === "inline"
                              ? aiInputMenuItemInlineDescription
                              : aiInputMenuItemDescription
                          }
                        >
                          {item.description}
                        </span>
                      ) : null}
                    </button>
                  );
                })}
              </div>
            ))}
            {browse.onLoadMore ? (
              <ScrollAreaLoadMore
                failed={browse.error !== undefined}
                hasMore={renderedCount >= items.length}
                loading={browse.loadingMore}
                onLoadMore={browse.onLoadMore}
                quiet
              />
            ) : null}
            {committing || browse.loadingMore ? (
              <AiInputMenuSearchingRow label={searchingLabel} />
            ) : null}
          </ScrollArea>
        )}
      </div>
    </div>
  );
};
