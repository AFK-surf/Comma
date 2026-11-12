/* oxlint-disable jsx-a11y/prefer-tag-over-role -- the filter field is a combobox over a listbox of option buttons, the same ARIA the list level keeps. */
import {
  startTransition,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
  type UIEvent,
} from "react";
import { ChevronLeftSmallIcon, ChevronRightSmallIcon } from "../../icons";
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
  aiInputMenuPanel,
  aiInputMenuItemChevron,
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
const CHOICES_WIDTH = 220;
/** The choices keep this far from the edge of where they can show (px). */
const CHOICES_EDGE_MARGIN = 8;
/**
 * With no room beside the panel the choices cover it whole, border on
 * border, and keep its bottom edge: taller than the panel, they rise above it.
 */
const CHOICES_OVER_PANEL = {
  bottom: "calc(-1 * var(--border-width-default))",
  left: "calc(-1 * var(--border-width-default))",
  width: "calc(100% + 2 * var(--border-width-default))",
  maxWidth: "none",
  minHeight: "calc(100% + 2 * var(--border-width-default))",
};
/** Distance from the bottom edge (px) at which the next chunk is committed. */
const RENDER_AHEAD_PX = 96;

export interface AiInputMenuBrowsePanelProps {
  backLabel: string;
  browse: AiInputMenuBrowse;
  /** False for the exit ghost, which must never take focus. */
  focusOnMount: boolean;
  /** Choices opened beside a row: the pointer can pick them unfocused. */
  nested?: boolean;
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
  nested = false,
  listId,
  onBack,
  onBlur,
  onSelectItem,
  optionId,
  searchingLabel,
}: AiInputMenuBrowsePanelProps) => {
  const inputRef = useRef<HTMLInputElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const submenuRef = useRef<HTMLDivElement>(null);
  const [submenu, setSubmenu] = useState<{
    item: AiInputMenuItem;
    top: number;
    left: boolean;
    overlay: boolean;
    keyboard: boolean;
  } | null>(null);
  const openSubmenu = (item: AiInputMenuItem, keyboard = false) => {
    if (!item.browse) {
      setSubmenu(null);
      return;
    }
    const row = document.getElementById(optionId(item.id) ?? "");
    const root = rootRef.current;
    if (!row || !root) return;
    const bounds = root.getBoundingClientRect();
    const visible = visibleBounds(root);
    if (!keyboard && submenuRef.current?.contains(document.activeElement)) {
      inputRef.current?.focus();
    }
    // Beside the panel where there is room: after it, else before it, else over it.
    const left = bounds.right + CHOICES_WIDTH > visible.right;
    setSubmenu({
      item,
      top: Math.max(0, row.getBoundingClientRect().top - bounds.top),
      left,
      overlay: left && bounds.left - CHOICES_WIDTH < visible.left,
      keyboard,
    });
  };
  const [submenuTop, setSubmenuTop] = useState(0);
  useLayoutEffect(() => {
    const panel = submenuRef.current;
    const root = rootRef.current;
    if (!submenu || submenu.overlay || !panel || !root) return;
    // Near the bottom of where they can show, the choices rise past the
    // panel's own top, as far as the top edge. They grow as their rows arrive.
    const place = () => {
      const rootTop = root.getBoundingClientRect().top;
      const visible = visibleBounds(root);
      const bottom =
        visible.bottom - CHOICES_EDGE_MARGIN - rootTop - panel.offsetHeight;
      setSubmenuTop(
        Math.max(
          visible.top + CHOICES_EDGE_MARGIN - rootTop,
          Math.min(submenu.top, bottom)
        )
      );
    };
    place();
    const observer = new ResizeObserver(place);
    observer.observe(panel);
    return () => observer.disconnect();
  }, [submenu]);
  // The pointer's previous position over the rows. A move from there that
  // heads into the open choices crosses other rows on its way; it must not
  // swap the choices for theirs.
  const pointerRef = useRef<Point | null>(null);
  const headsIntoSubmenu = (from: Point | null, x: number, y: number) => {
    const panel = submenuRef.current;
    if (!from || !panel || !submenu || submenu.overlay) return false;
    const bounds = panel.getBoundingClientRect();
    const edge = submenu.left ? bounds.right : bounds.left;
    return insideTriangle(
      { x, y },
      from,
      { x: edge, y: bounds.top },
      { x: edge, y: bounds.bottom }
    );
  };
  const pickItem = (item: AiInputMenuItem) =>
    item.browse ? openSubmenu(item, true) : onSelectItem(item);
  const [query, setQuery] = useState(initialQuery);
  // Filtering a whole source is deferred: keystrokes land in the field at
  // once, the rows follow, and the gap between the two — real only for a
  // source large enough to have one — reads as searching.
  const deferredQuery = useDeferredValue(query);
  const searching = deferredQuery !== query;
  const queryChanged = browse.onQueryChange;
  useEffect(() => {
    if (!focusOnMount && !nested) return;
    queryChanged?.(query);
    return () => queryChanged?.(null);
  }, [focusOnMount, nested, query, queryChanged]);
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
    if (focusOnMount) inputRef.current?.focus({ preventScroll: true });
  }, [focusOnMount]);

  const handlePointerMove = useAiInputMenuNavigation(
    optionId(items[activeIndex]?.id),
    items,
    setActiveIndex,
    focusOnMount || nested
  );

  const handleScroll = (event: UIEvent<HTMLDivElement>) => {
    if (committing) return;
    setSubmenu(null);
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

    if (
      event.key === "ArrowRight" &&
      items[activeIndex]?.browse &&
      input.selectionStart === input.value.length &&
      input.selectionEnd === input.value.length
    ) {
      event.preventDefault();
      openSubmenu(items[activeIndex]!, true);
      return;
    }
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
      setSubmenu(null);
      setActiveIndex((current) => (current + delta + items.length) % items.length);
      return;
    }

    if (event.key === "Enter" || event.key === "Tab") {
      event.preventDefault();
      const item = items[activeIndex] ?? items[0];
      if (item) pickItem(item);
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
  // The open row as it is now: what stands behind it can arrive while it is open.
  const submenuBrowse =
    submenu &&
    (items.find((item) => item.id === submenu.item.id) ?? submenu.item).browse;
  const activeOptionId = optionId(items[activeIndex]?.id);

  return (
    <div
      className={`${aiInputMenuBrowse} relative`}
      data-testid="ai-input-menu-browse"
      ref={rootRef}
      style={
        browse.compact
          ? { maxHeight: AI_INPUT_MENU_MAX_HEIGHT_PX }
          : { height: AI_INPUT_MENU_MAX_HEIGHT_PX }
      }
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
        onChange={(event) => {
          setSubmenu(null);
          setQuery(event.currentTarget.value);
        }}
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
            className="flex min-h-0 w-full flex-1 flex-col"
            contentClassName={aiInputMenuScrollContent}
            onScroll={handleScroll}
            orientation="vertical"
            viewportClassName="min-h-0 flex-1"
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
                        pickItem(item);
                      }}
                      onPointerMove={(event) => {
                        const from = pointerRef.current;
                        const { clientX: x, clientY: y } = event;
                        pointerRef.current = { x, y };
                        if (submenu?.item.id === item.id) {
                          handlePointerMove(event, itemIndex);
                          return;
                        }
                        if (headsIntoSubmenu(from, x, y)) return;
                        if (handlePointerMove(event, itemIndex)) openSubmenu(item);
                      }}
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
                      {item.browse ? (
                        <span aria-hidden className={aiInputMenuItemChevron}>
                          <ChevronRightSmallIcon />
                        </span>
                      ) : null}
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
      {submenuBrowse && submenu ? (
        <div
          className={aiInputMenuPanel}
          ref={submenuRef}
          style={
            submenu.overlay
              ? CHOICES_OVER_PANEL
              : {
                  top: submenuTop,
                  width: CHOICES_WIDTH,
                  ...(submenu.left ? { right: "100%" } : { left: "100%" }),
                }
          }
        >
          <AiInputMenuBrowsePanel
            key={submenu.item.id}
            backLabel={backLabel}
            browse={submenuBrowse}
            focusOnMount={submenu.keyboard}
            nested
            group={{ id: submenu.item.id, items: [], browse: submenuBrowse }}
            initialQuery=""
            listId={`${listId}-choices`}
            onBack={() => {
              setSubmenu(null);
              inputRef.current?.focus();
            }}
            onBlur={(next) => {
              if (!next || !rootRef.current?.contains(next)) onBlur(next);
            }}
            onSelectItem={onSelectItem}
            optionId={optionId}
            searchingLabel={searchingLabel}
          />
        </div>
      ) : null}
    </div>
  );
};

/**
 * Where a box placed against `element` can show: the window, cut down by each
 * ancestor that clips its overflow. A pane narrower than the window clips the
 * choices at its own edge, not the window's.
 */
function visibleBounds(element: HTMLElement) {
  const visible = {
    top: 0,
    left: 0,
    right: window.innerWidth,
    bottom: window.innerHeight,
  };
  let position = getComputedStyle(element).position;
  for (let node = element.parentElement; node; node = node.parentElement) {
    const style = getComputedStyle(node);
    // An absolutely positioned box is clipped from its containing block up:
    // the unpositioned ancestors below that do not hold it.
    if (position === "absolute" && style.position === "static") continue;
    position = style.position;
    const box = node.getBoundingClientRect();
    if (style.overflowX !== "visible") {
      const left = box.left + node.clientLeft;
      visible.left = Math.max(visible.left, left);
      visible.right = Math.min(visible.right, left + node.clientWidth);
    }
    if (style.overflowY !== "visible") {
      const top = box.top + node.clientTop;
      visible.top = Math.max(visible.top, top);
      visible.bottom = Math.min(visible.bottom, top + node.clientHeight);
    }
  }
  return visible;
}

type Point = { x: number; y: number };

/** Whether `p` lies inside the triangle `a`, `b`, `c` (either winding). */
function insideTriangle(p: Point, a: Point, b: Point, c: Point) {
  const side = (from: Point, to: Point) =>
    (to.x - from.x) * (p.y - from.y) - (to.y - from.y) * (p.x - from.x);
  const ab = side(a, b);
  const bc = side(b, c);
  const ca = side(c, a);
  return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0);
}
