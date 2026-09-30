import {
  isValidElement,
  useCallback,
  useEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type Key,
  type ElementType,
  type ReactElement,
  type ReactNode,
} from "react";
import {
  getMenuPointerOffsets,
  Menu,
  MenuPopover,
  type MenuPointerOffsets,
  type MenuProps,
} from "../menu";
import { cx } from "../utils";
import {
  taskListItemDisabled,
  taskListItemDot,
  taskListItemDotInner,
  taskListItemDotTrack,
  taskListItemContentHandle,
  taskListItemContentMain,
  taskListItemIconLayer,
  taskListItemIconSlot,
  taskListItemIconSlotByLayout,
  taskListItemInteractive,
  taskListItemRootByLayout,
  taskListItemSelected,
  taskListItemChecked,
  taskListItemSidebarMain,
  taskListItemTailByLayout,
  taskListItemTailContents,
  taskListItemTailDate,
  taskListItemTitleByLayout,
  type TaskListItemLayout,
  taskListItemBadges,
} from "./styles";

/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
/* oxlint-disable jsx-a11y/no-static-element-interactions -- Task rows preserve consumer-owned semantics while supporting native context-menu shortcuts. */

const iconAnimationDurationMs = 220;

type IconSnapshot = {
  key: Key;
  node: ReactNode;
};

export interface TaskListItemContextMenuProps extends Omit<
  MenuProps,
  "autoFocus" | "children" | "onClose"
> {
  children: ReactNode;
}

export interface TaskListItemProps extends Omit<
  HTMLAttributes<HTMLElement>,
  "contextMenu" | "title"
> {
  /** Semantic root element. Use `button` when the row itself performs an action. */
  as?: "button" | "div";
  icon: ReactNode;
  iconKey?: Key;
  dot?: boolean;
  title: ReactNode;
  /** Chips shown after the title, ahead of the tail (content layout only). */
  badges?: ReactNode;
  /** Sits ahead of the status icon (content layout only): a selection checkbox. */
  leading?: ReactNode;
  tail?: ReactNode;
  layout?: TaskListItemLayout;
  selected?: boolean;
  /** Part of a multi-selection (brand wash). */
  checked?: boolean;
  disabled?: boolean;
  dotClassName?: string;
  titleClassName?: string;
  tailClassName?: string;
  contextMenu?: TaskListItemContextMenuProps;
  onContextMenuOpenChange?: (open: boolean) => void;
}

const displayNameFromElement = (element: ReactElement) => {
  if (typeof element.type === "string") return element.type;
  if (typeof element.type === "function") {
    const namedType = element.type as { displayName?: string; name?: string };
    return namedType.displayName ?? namedType.name ?? "icon";
  }
  const namedType = element.type as { displayName?: string; name?: string };
  return namedType.displayName ?? namedType.name ?? "icon";
};

const iconIdentity = (icon: ReactNode, explicitKey?: Key): Key => {
  if (explicitKey !== undefined) return explicitKey;
  if (isValidElement(icon)) return icon.key ?? displayNameFromElement(icon);
  if (typeof icon === "string" || typeof icon === "number") return icon;
  return "icon";
};

const TaskListItemIconSlot = ({
  icon,
  iconKey,
  layout,
}: {
  icon: ReactNode;
  iconKey?: Key;
  layout: TaskListItemLayout;
}) => {
  const resolvedKey = iconIdentity(icon, iconKey);
  const snapshotRef = useRef({
    currentKey: resolvedKey,
    currentIcon: icon,
    previous: null as IconSnapshot | null,
  });
  const [, setRenderVersion] = useState(0);
  const snapshot = snapshotRef.current;

  if (Object.is(snapshot.currentKey, resolvedKey)) {
    snapshot.currentIcon = icon;
  }

  useEffect(() => {
    if (Object.is(snapshot.currentKey, resolvedKey)) {
      snapshot.currentIcon = icon;
      return undefined;
    }

    snapshot.previous = { key: snapshot.currentKey, node: snapshot.currentIcon };
    snapshot.currentKey = resolvedKey;
    snapshot.currentIcon = icon;
    setRenderVersion((value) => value + 1);

    const timeout = window.setTimeout(() => {
      snapshot.previous = null;
      setRenderVersion((value) => value + 1);
    }, iconAnimationDurationMs);

    return () => window.clearTimeout(timeout);
  }, [icon, resolvedKey, snapshot]);
  const currentIcon = { key: snapshot.currentKey, node: snapshot.currentIcon };
  const previousIcon = snapshot.previous;

  return (
    <span
      aria-hidden
      className={cx(taskListItemIconSlot, taskListItemIconSlotByLayout[layout])}
      data-slot="task-list-item-icon"
    >
      {previousIcon ? (
        <span
          className={taskListItemIconLayer}
          data-motion="exit"
          key={`previous-${String(previousIcon.key)}`}
        >
          {previousIcon.node}
        </span>
      ) : null}
      <span
        className={taskListItemIconLayer}
        data-motion={previousIcon ? "enter" : "idle"}
        key={`current-${String(currentIcon.key)}`}
      >
        {currentIcon.node}
      </span>
    </span>
  );
};

export const TaskListItem = ({
  as: element = "div",
  icon,
  iconKey,
  dot = false,
  title,
  badges,
  leading,
  tail,
  layout = "content",
  selected = false,
  checked = false,
  disabled = false,
  dotClassName,
  titleClassName,
  tailClassName,
  contextMenu,
  onContextMenu,
  onContextMenuOpenChange,
  onKeyDown,
  tabIndex,
  "aria-disabled": ariaDisabled,
  "aria-haspopup": ariaHasPopup,
  className,
  ...rest
}: TaskListItemProps) => {
  const Root: ElementType = element;
  const rootRef = useRef<HTMLElement>(null);
  const setRootRef = (node: HTMLElement | null) => {
    rootRef.current = node;
  };
  const isContextMenuOpenRef = useRef(false);
  const [isContextMenuOpen, setIsContextMenuOpen] = useState(false);
  const [shouldRestoreContextMenuFocus, setShouldRestoreContextMenuFocus] =
    useState(false);
  const [menuPointerOffsets, setMenuPointerOffsets] =
    useState<MenuPointerOffsets | null>(null);

  const handleContextMenuOpenChange = useCallback(
    (open: boolean) => {
      if (isContextMenuOpenRef.current === open) return;

      isContextMenuOpenRef.current = open;
      if (!open) setShouldRestoreContextMenuFocus(!disabled);
      setIsContextMenuOpen(open);
      onContextMenuOpenChange?.(open);
    },
    [disabled, onContextMenuOpenChange]
  );

  const openContextMenu = (pointerOffsets: MenuPointerOffsets | null) => {
    const root = rootRef.current;
    if (!root || disabled || !contextMenu) return;

    root.focus({ preventScroll: true });
    setMenuPointerOffsets(pointerOffsets);
    handleContextMenuOpenChange(true);
  };

  useEffect(() => {
    if (isContextMenuOpen && (disabled || !contextMenu)) {
      handleContextMenuOpenChange(false);
    }
  }, [contextMenu, disabled, handleContextMenuOpenChange, isContextMenuOpen]);

  useEffect(() => {
    if (isContextMenuOpen || !shouldRestoreContextMenuFocus) return;

    rootRef.current?.focus({ preventScroll: true });
    setShouldRestoreContextMenuFocus(false);
  }, [isContextMenuOpen, shouldRestoreContextMenuFocus]);

  const hasContextMenuTrigger =
    Boolean(contextMenu) || isContextMenuOpen || shouldRestoreContextMenuFocus;

  return (
    <>
      <Root
        aria-disabled={ariaDisabled ?? (disabled ? true : undefined)}
        aria-haspopup={ariaHasPopup ?? (contextMenu ? "menu" : undefined)}
        className={cx(
          taskListItemRootByLayout[layout],
          !disabled && taskListItemInteractive,
          !disabled && "focus-visible:shadow-focus-gray",
          (selected || isContextMenuOpen) && taskListItemSelected,
          checked && taskListItemChecked,
          disabled && taskListItemDisabled,
          className
        )}
        data-checked={checked ? "true" : undefined}
        data-context-menu-open={isContextMenuOpen ? "true" : "false"}
        data-disabled={disabled ? "true" : undefined}
        data-selected={selected ? "true" : undefined}
        data-slot="task-list-item"
        {...(element === "button" ? { disabled, type: "button" } : {})}
        {...rest}
        onContextMenu={(event) => {
          onContextMenu?.(event);
          if (event.defaultPrevented || disabled || !contextMenu || !rootRef.current) {
            return;
          }

          event.preventDefault();
          openContextMenu(
            getMenuPointerOffsets(rootRef.current, event.clientX, event.clientY)
          );
        }}
        onKeyDown={(event) => {
          onKeyDown?.(event);
          if (
            event.defaultPrevented ||
            (event.key !== "ContextMenu" && !(event.shiftKey && event.key === "F10"))
          ) {
            return;
          }

          event.preventDefault();
          openContextMenu(null);
        }}
        ref={setRootRef}
        tabIndex={tabIndex ?? (hasContextMenuTrigger ? (disabled ? -1 : 0) : undefined)}
      >
        {layout === "content" ? (
          <>
            <div className={taskListItemContentMain} data-slot="task-list-item-main">
              <span
                aria-hidden
                className={taskListItemContentHandle}
                data-slot="task-list-item-handle"
              />
              {leading}
              <TaskListItemIconSlot
                icon={icon}
                layout={layout}
                {...(iconKey !== undefined ? { iconKey } : {})}
              />
              <span
                className={cx(taskListItemTitleByLayout[layout], titleClassName)}
                data-slot="task-list-item-title"
              >
                {title}
              </span>
            </div>
            {badges ? (
              <span className={taskListItemBadges} data-slot="task-list-item-badges">
                {badges}
              </span>
            ) : null}
            {tail ? (
              <span
                className={taskListItemTailContents}
                data-slot="task-list-item-tail"
              >
                {typeof tail === "string" ? (
                  <span className={taskListItemTailDate}>{tail}</span>
                ) : (
                  tail
                )}
              </span>
            ) : null}
          </>
        ) : (
          <>
            <div className={taskListItemSidebarMain} data-slot="task-list-item-main">
              <TaskListItemIconSlot
                icon={icon}
                layout={layout}
                {...(iconKey !== undefined ? { iconKey } : {})}
              />
              <span
                aria-hidden
                className={taskListItemDotTrack}
                data-slot="task-list-item-dot"
                data-state={dot ? "visible" : "hidden"}
              >
                <span className={taskListItemDotInner}>
                  <span className={cx(taskListItemDot, dotClassName)} />
                </span>
              </span>
              <span
                className={cx(taskListItemTitleByLayout[layout], titleClassName)}
                data-slot="task-list-item-title"
              >
                {title}
              </span>
            </div>
            {tail ? (
              <span
                className={cx(taskListItemTailByLayout[layout], tailClassName)}
                data-slot="task-list-item-tail"
              >
                {tail}
              </span>
            ) : null}
          </>
        )}
      </Root>
      {contextMenu ? (
        <MenuPopover
          crossOffset={menuPointerOffsets?.crossOffset ?? 0}
          dismissControlledNonModalOnInteractOutside
          isNonModal
          isOpen={isContextMenuOpen}
          offset={menuPointerOffsets?.offset ?? 0}
          onOpenChange={handleContextMenuOpenChange}
          placement="right top"
          triggerRef={rootRef}
        >
          <Menu
            {...contextMenu}
            autoFocus="first"
            onClose={() => handleContextMenuOpenChange(false)}
          />
        </MenuPopover>
      ) : null}
    </>
  );
};
