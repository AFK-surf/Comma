/* oxlint-disable jsx-a11y/prefer-tag-over-role -- combobox popup keeps ARIA listbox/option semantics with button mouse affordances. */
import {
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type Ref,
  type UIEvent,
} from "react";
import { ChevronRightSmallIcon } from "../../icons";
import { ScrollArea } from "../../scroll-area";
import { useAiInputMenuNavigation } from "./useAiInputMenuNavigation";
import { AiInputMenuBrowsePanel } from "./AiInputMenuBrowsePanel";
import { AiInputMenuSearchingRow } from "./AiInputMenuSearchingText";
import type { AiInputMenuGroup, AiInputMenuItem } from "../richText";
import {
  AI_INPUT_MENU_MAX_HEIGHT_PX,
  aiInputMenuItem,
  aiInputMenuItemChevron,
  aiInputMenuItemDescription,
  aiInputMenuItemIcon,
  aiInputMenuItemLabel,
  aiInputMenuItemInlineLabel,
  aiInputMenuItemInlineDescription,
  aiInputMenuLevelBrowse,
  aiInputMenuLevelList,
  aiInputMenuPanel,
  aiInputMenuScrollContent,
  aiInputMenuSection,
  aiInputMenuSectionLabel,
  aiInputMenuStateRow,
} from "../styles";

/**
 * Rows committed per lazy-render step. Rows are a fixed 28px, so one chunk
 * more than fills the 320px viewport and the next chunk is ready before the
 * reader can scroll into the gap.
 */
const RENDER_CHUNK = 48;
/** Distance from the bottom edge (px) at which the next chunk is committed. */
const RENDER_AHEAD_PX = 96;

/** A group's browse panel, open in place of the list. */
export interface AiInputMenuBrowseState {
  backLabel: string;
  /** The group whose `browse` is open. */
  group: AiInputMenuGroup;
  /** The trigger query typed so far, carried into the panel's search. */
  initialQuery: string;
  onBack: () => void;
  /** Focus left the panel for somewhere outside it and the editor decides. */
  onBlur: (relatedTarget: Element | null) => void;
}

export interface AiInputMenuPanelProps {
  activeIndex: number;
  /** Set while a group's browse panel replaces the list. */
  browse?: AiInputMenuBrowseState | undefined;
  groups: readonly AiInputMenuGroup[];
  /** Flat selectable items across groups, in render order. */
  items: readonly AiInputMenuItem[];
  label: string;
  menuId: string;
  noResultsLabel: string;
  onHoverItem: (index: number) => void;
  onSelectItem: (item: AiInputMenuItem) => void;
  optionId: (itemId: string | undefined) => string | undefined;
  /** The panel's root, so the editor can tell a blur into the panel from one out of it. */
  panelRef?: Ref<HTMLDivElement> | undefined;
  /** Resets the lazy render window when the trigger or query changes. */
  resetKey: string;
  searchingLabel: string;
  /**
   * "closed" renders the exit ghost: same node fading out on the menu-exit
   * cadence, inert and out of the accessibility tree while it goes.
   */
  state?: "open" | "closed";
  /** Caret-anchored placement (left/bottom/width) supplied by the editor. */
  style?: CSSProperties | undefined;
}

export const AiInputMenuPanel = ({
  activeIndex,
  browse,
  groups,
  items,
  label,
  menuId,
  noResultsLabel,
  onHoverItem,
  onSelectItem,
  optionId,
  panelRef,
  resetKey,
  searchingLabel,
  state = "open",
  style,
}: AiInputMenuPanelProps) => {
  const [renderLimit, setRenderLimit] = useState(RENDER_CHUNK);
  const previousResetKeyRef = useRef(resetKey);
  // The list fades in only when it is returning from a browse panel;
  // its first paint rides the popover's own enter instead.
  const wasBrowsingRef = useRef(false);
  const returned = !browse && wasBrowsingRef.current;
  wasBrowsingRef.current = Boolean(browse);

  // Reset the window synchronously with a new trigger/query so a long list
  // from the previous query never paints for one frame under the new one.
  if (previousResetKeyRef.current !== resetKey) {
    previousResetKeyRef.current = resetKey;
    if (renderLimit !== RENDER_CHUNK) setRenderLimit(RENDER_CHUNK);
  }

  // Keyboard selection may step past the window; widening is derived (not
  // state) so aria-activedescendant always references a mounted option.
  const effectiveLimit = Math.max(
    renderLimit,
    Math.ceil((activeIndex + 1) / RENDER_CHUNK) * RENDER_CHUNK
  );

  const anyLoading = groups.some((group) => group.status === "loading");

  // Sections still indexing collapse into one trailing searching row instead
  // of stacking a shimmer under every pending header.
  const renderedGroups = useMemo(() => {
    let taken = 0;
    return groups.flatMap((group) => {
      if (taken >= effectiveLimit || group.items.length === 0) return [];
      const visible = group.items.slice(0, effectiveLimit - taken);
      const startIndex = taken;
      taken += visible.length;
      return [{ group, startIndex, visible }];
    });
  }, [effectiveLimit, groups]);

  const renderedCount = useMemo(
    () => renderedGroups.reduce((sum, entry) => sum + entry.visible.length, 0),
    [renderedGroups]
  );

  const handleScroll = (event: UIEvent<HTMLDivElement>) => {
    if (renderedCount >= items.length) return;
    const viewport = event.currentTarget;
    const remaining =
      viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
    if (remaining <= RENDER_AHEAD_PX) {
      setRenderLimit(effectiveLimit + RENDER_CHUNK);
    }
  };

  const handlePointerMove = useAiInputMenuNavigation(
    optionId(items[activeIndex]?.id),
    items,
    onHoverItem,
    !browse && state === "open"
  );

  const isEmpty = items.length === 0;
  const open = state === "open";

  return (
    <div
      className={aiInputMenuPanel}
      data-state={state}
      data-testid="ai-input-menu"
      ref={panelRef}
      style={style}
      {...(!open
        ? { "aria-hidden": true }
        : browse
          ? { "aria-label": browse.group.browse?.title, role: "dialog" }
          : { "aria-label": label, id: menuId, role: "listbox" })}
    >
      {browse?.group.browse ? (
        <div className={aiInputMenuLevelBrowse} data-level="browse" key="browse">
          <AiInputMenuBrowsePanel
            backLabel={browse.backLabel}
            browse={browse.group.browse}
            focusOnMount={open}
            group={browse.group}
            initialQuery={browse.initialQuery}
            listId={menuId}
            onBack={browse.onBack}
            onBlur={browse.onBlur}
            onSelectItem={onSelectItem}
            optionId={optionId}
            searchingLabel={searchingLabel}
          />
        </div>
      ) : (
        <div
          className={aiInputMenuLevelList}
          data-level="list"
          data-returned={returned ? "true" : undefined}
          key="list"
        >
          {isEmpty && anyLoading ? (
            <AiInputMenuSearchingRow label={searchingLabel} />
          ) : isEmpty ? (
            <div className={aiInputMenuStateRow} data-testid="ai-input-menu-no-results">
              <span className="min-w-0 truncate">{noResultsLabel}</span>
            </div>
          ) : (
            <ScrollArea
              className="w-full"
              contentClassName={aiInputMenuScrollContent}
              onScroll={handleScroll}
              orientation="vertical"
              viewportProps={{
                style: { maxHeight: AI_INPUT_MENU_MAX_HEIGHT_PX },
                tabIndex: -1,
              }}
            >
              {renderedGroups.map(({ group, startIndex, visible }) => (
                <div className={aiInputMenuSection} key={group.id} role="group">
                  {group.label ? (
                    <div className={aiInputMenuSectionLabel}>{group.label}</div>
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
                        {item.browseGroupId ? (
                          <span aria-hidden className={aiInputMenuItemChevron}>
                            <ChevronRightSmallIcon />
                          </span>
                        ) : null}
                      </button>
                    );
                  })}
                </div>
              ))}
              {anyLoading ? <AiInputMenuSearchingRow label={searchingLabel} /> : null}
            </ScrollArea>
          )}
        </div>
      )}
    </div>
  );
};
