import {
  createContext,
  forwardRef,
  Fragment,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ForwardedRef,
  type ReactNode,
  type RefObject,
} from "react";
import { mergeRefs, useInteractOutside } from "react-aria";
import type {
  MenuItemProps as AriaMenuItemProps,
  MenuProps as AriaMenuProps,
  MenuTriggerProps as AriaMenuTriggerProps,
  SubmenuTriggerProps as AriaSubmenuTriggerProps,
  PopoverProps as AriaPopoverProps,
  SeparatorProps as AriaSeparatorProps,
} from "react-aria-components";
import {
  Menu as AriaMenu,
  MenuItem as AriaMenuItem,
  MenuTrigger as AriaMenuTrigger,
  OverlayTriggerStateContext,
  PopoverContext,
  useSlottedContext,
  RootMenuTriggerStateContext,
  SubmenuTrigger as AriaSubmenuTrigger,
  Popover as AriaPopover,
  Separator as AriaSeparator,
} from "react-aria-components";
import { borderWidth, motionDuration, spacing, typeScale } from "../../tokens";
import { CheckboxBase } from "../checkbox/CheckboxBase";
import { CheckLargeIcon } from "../icons";
import {
  SelectionAlignedRevealIndicator,
  useSelectionAlignedPopover,
} from "../dropdown/select-primitives";
import { ScrollArea } from "../scroll-area";
import { cx, definedProps } from "../utils";
import {
  menuClasses,
  menuEmbeddedClasses,
  menuItemClasses,
  menuPopoverClasses,
  menuPopoverEnteringClasses,
  menuPopoverExitingClasses,
  menuPopoverFadeClasses,
  menuPopoverFadeEnteringClasses,
  menuPopoverFadeExitingClasses,
  menuPopoverInPlaceExitingClasses,
  menuPopoverStaticClasses,
  menuPopoverStaticExitingClasses,
  menuSeparatorClasses,
  menuSurfaceClasses,
} from "./styles";

export interface MenuProps<T extends object = object> extends Omit<
  AriaMenuProps<T>,
  "className"
> {
  className?: string;
  variant?: "embedded" | "surface";
}

export type MenuItemTone = "default" | "destructive";
export type MenuItemAppearance = "default" | "sidebar";

export interface MenuItemProps<T extends object = object> extends Omit<
  AriaMenuItemProps<T>,
  "children" | "className"
> {
  activeClassName?: string;
  appearance?: MenuItemAppearance;
  children?: ReactNode;
  contentClassName?: string;
  icon?: ReactNode;
  gutter?: "default" | "none";
  layout?: "row" | "tile";
  /**
   * How a selectable row shows its state: a checkbox for multi-select filters,
   * or a plain checkmark (Central checkmark-1) for single-select pickers, where
   * exactly one row is ever marked and the others keep the slot empty.
   */
  selectionIndicator?: "checkbox" | "check";
  shortcut?: ReactNode;
  tone?: MenuItemTone;
  className?: string;
}

/** Standard height of one row-layout menu item, in px. */
export const menuSelectionRowHeight = typeScale.textSm.lineHeight + spacing.sm * 2;

export interface MenuPopoverSelectionAlignment {
  /** Rows the menu renders, in order, mirroring their `separatorBefore` flags. */
  items: ReadonlyArray<{ separatorBefore?: boolean }>;
  /** Height of one menu row in px; defaults to `menuSelectionRowHeight`. */
  rowHeight?: number;
  /** Index of the checked row that opens over the trigger. */
  selectedIndex: number;
  size?: "xs" | "sm" | "md";
  /** The trigger element the checked row's center aligns over. */
  triggerRef: RefObject<HTMLElement | null>;
}

export interface MenuPopoverProps extends Omit<AriaPopoverProps, "className"> {
  /** Root menus move from their anchor. Submenus fade. In-place surfaces fade only on exit. */
  animation?: "anchor" | "auto" | "fade" | "in-place" | "none";
  className?: string;
  closeSubmenusOnPointerLeave?: boolean;
  /** Preserve outside-pointer dismissal for a controlled root non-modal popover. */
  dismissControlledNonModalOnInteractOutside?: boolean;
  /**
   * macOS-pop-up positioning for single-selection menus: the checked row opens
   * over the trigger and the position follows the selection on every open.
   * Near the viewport bottom the menu clamps and reveals clipped rows when the
   * pointer reaches the bottom chevron. Pass plain-node children (typically a
   * `<Menu variant="embedded">`); the popover renders the menu surface itself.
   */
  selectionAlign?: MenuPopoverSelectionAlignment;
}

export interface MenuSeparatorProps extends Omit<AriaSeparatorProps, "className"> {
  className?: string;
}

export type MenuTriggerProps = AriaMenuTriggerProps;
export type SubmenuTriggerProps = AriaSubmenuTriggerProps;

export const Menu = <T extends object = object>({
  className,
  variant = "surface",
  ...props
}: MenuProps<T>) => (
  <AriaMenu<T>
    {...props}
    className={cx(
      variant === "embedded" ? menuEmbeddedClasses : menuClasses,
      className
    )}
    data-slot="menu"
    data-variant={variant}
  />
);

export const MenuItem = <T extends object = object>({
  activeClassName,
  appearance = "default",
  children,
  className,
  contentClassName,
  gutter = "default",
  icon,
  layout = "row",
  selectionIndicator,
  shortcut,
  textValue,
  tone = "default",
  ...props
}: MenuItemProps<T>) => {
  const resolvedTextValue =
    textValue ?? (typeof children === "string" ? children : undefined);

  return (
    <AriaMenuItem<T>
      {...props}
      {...definedProps({ textValue: resolvedTextValue })}
      className={(state) =>
        cx(
          menuItemClasses.root,
          gutter === "default" && menuItemClasses.gutter,
          className,
          state.isDisabled && menuItemClasses.disabled
        )
      }
      data-slot="menu-item"
      data-appearance={appearance}
      data-tone={tone}
    >
      {(state) => {
        const isActive =
          !state.isDisabled &&
          (state.isPressed ||
            state.isOpen ||
            (state.isFocused && (state.isHovered || state.isFocusVisible)));

        return (
          <div
            className={cx(
              menuItemClasses.content,
              layout === "row" ? menuItemClasses.row : menuItemClasses.tile,
              appearance === "sidebar" && menuItemClasses.sidebar,
              contentClassName,
              tone === "destructive" && menuItemClasses.destructive,
              state.isDisabled ? "cursor-not-allowed" : menuItemClasses.interactive,
              isActive &&
                (layout === "row" || !state.isSelected) &&
                (tone === "destructive"
                  ? menuItemClasses.activeDestructive
                  : (activeClassName ??
                    (appearance === "sidebar"
                      ? menuItemClasses.activeSidebar
                      : menuItemClasses.active))),
              state.isPressed &&
                (layout === "row"
                  ? menuItemClasses.pressed
                  : menuItemClasses.tilePressed),
              layout === "tile" && state.isSelected && menuItemClasses.tileSelected,
              state.isFocusVisible &&
                (layout === "row"
                  ? menuItemClasses.focused
                  : menuItemClasses.tileFocused)
            )}
            data-slot="menu-item-content"
          >
            <span
              className={cx(
                layout === "row" ? menuItemClasses.leading : menuItemClasses.leadingTile
              )}
              data-slot="menu-item-leading"
            >
              {selectionIndicator === "checkbox" ? (
                <span aria-hidden data-slot="menu-item-selection-indicator">
                  <CheckboxBase
                    className={cx(
                      !state.isSelected &&
                        !state.isHovered &&
                        !state.isFocusVisible &&
                        "opacity-0"
                    )}
                    isSelected={state.isSelected}
                    size="sm"
                  />
                </span>
              ) : null}
              {selectionIndicator === "check" ? (
                <span
                  aria-hidden
                  className={cx(menuItemClasses.icon, !state.isSelected && "invisible")}
                  data-slot="menu-item-selection-indicator"
                >
                  <CheckLargeIcon />
                </span>
              ) : null}
              {icon && (
                <span
                  aria-hidden
                  className={cx(
                    layout === "row" ? menuItemClasses.icon : menuItemClasses.iconTile,
                    appearance === "sidebar"
                      ? menuItemClasses.iconSidebar
                      : tone !== "destructive" &&
                          state.isHovered &&
                          layout === "row" &&
                          menuItemClasses.iconHovered
                  )}
                  data-slot="menu-item-icon"
                >
                  {icon}
                </span>
              )}
              <span
                className={cx(
                  layout === "row" ? menuItemClasses.label : menuItemClasses.labelTile
                )}
                data-slot="menu-item-label"
              >
                {children}
              </span>
            </span>
            {shortcut && (
              <span
                aria-hidden
                className={menuItemClasses.shortcut}
                data-slot="menu-item-shortcut"
              >
                {shortcut}
              </span>
            )}
          </div>
        );
      }}
    </AriaMenuItem>
  );
};

export const MenuSeparator = ({ className, ...props }: MenuSeparatorProps) => (
  <AriaSeparator
    {...props}
    className={cx(menuSeparatorClasses, className)}
    data-slot="menu-separator"
  />
);

export const MenuTrigger = AriaMenuTrigger;
export const SubmenuTrigger = AriaSubmenuTrigger;

interface MenuPopoverGroup {
  popovers: Set<HTMLElement>;
  rootPopover: HTMLElement | null;
}

const MenuPopoverGroupContext = createContext<MenuPopoverGroup | null>(null);

function findExpandedSubmenuTrigger(popover: HTMLElement) {
  const labelledBy = popover.getAttribute("aria-labelledby");
  if (!labelledBy) return null;

  for (const id of labelledBy.split(/\s+/)) {
    const candidate = popover.ownerDocument.getElementById(id);
    if (
      candidate instanceof HTMLElement &&
      candidate.isConnected &&
      candidate.getAttribute("role") === "menuitem" &&
      candidate.getAttribute("aria-expanded") === "true"
    ) {
      return candidate;
    }
  }

  return null;
}

function preserveSubmenuTriggerFocus(
  popover: HTMLElement,
  key: string,
  group: MenuPopoverGroup | null
) {
  const ownerWindow = popover.ownerDocument.defaultView;
  const rootPopover = group?.rootPopover;
  if (!group || !ownerWindow || !rootPopover?.isConnected) return;

  const direction = ownerWindow.getComputedStyle(popover).direction;
  const directionalCloseKey = direction === "rtl" ? "ArrowRight" : "ArrowLeft";
  if (key !== "Escape" && key !== directionalCloseKey) return;

  const trigger = findExpandedSubmenuTrigger(popover);
  const triggerBelongsToGroup =
    trigger &&
    [...group.popovers].some((groupPopover) => groupPopover.contains(trigger));
  if (!trigger || !triggerBelongsToGroup) return;

  // An animation-free overlay can unmount after React Aria's synchronous focus
  // return and leave the document body focused. Reassert only that lost-focus case.
  ownerWindow.requestAnimationFrame(() => {
    const activeElement = popover.ownerDocument.activeElement;
    const focusWasLost =
      activeElement == null ||
      activeElement === popover.ownerDocument.body ||
      !activeElement.isConnected;

    if (
      rootPopover.isConnected &&
      trigger.isConnected &&
      trigger.getAttribute("aria-expanded") !== "true" &&
      focusWasLost
    ) {
      trigger.focus({ preventScroll: true });
    }
  });
}

function useMenuPopoverRef(
  group: MenuPopoverGroup | null,
  forwardedRef: ForwardedRef<HTMLDivElement>,
  isGroupRoot: boolean,
  onKeyDownCapture: (event: KeyboardEvent) => void
) {
  const registeredPopoverRef = useRef<HTMLDivElement | null>(null);
  const registerPopover = useCallback(
    (popover: HTMLDivElement | null) => {
      const previousPopover = registeredPopoverRef.current;
      if (previousPopover) {
        previousPopover.removeEventListener("keydown", onKeyDownCapture, true);
        group?.popovers.delete(previousPopover);
        if (group?.rootPopover === previousPopover) {
          group.rootPopover = null;
        }
      }

      registeredPopoverRef.current = popover;
      if (popover) {
        popover.addEventListener("keydown", onKeyDownCapture, true);
        group?.popovers.add(popover);
        if (group && isGroupRoot) {
          group.rootPopover = popover;
        }
      }
    },
    [group, isGroupRoot, onKeyDownCapture]
  );

  return useMemo(
    () => mergeRefs(forwardedRef, registerPopover),
    [forwardedRef, registerPopover]
  );
}

function useCloseSubmenusOnPointerLeave(isEnabled: boolean, group: MenuPopoverGroup) {
  const rootMenuState = useContext(RootMenuTriggerStateContext);
  const rootMenuStateRef = useRef(rootMenuState);
  const isRootMenuOpen = rootMenuState?.isOpen ?? false;
  rootMenuStateRef.current = rootMenuState;

  useEffect(() => {
    if (!isEnabled || !isRootMenuOpen) {
      return;
    }

    let closeTimeout: ReturnType<typeof setTimeout> | undefined;
    let pointerPosition: { x: number; y: number } | undefined;

    const cancelClose = () => {
      if (closeTimeout) {
        clearTimeout(closeTimeout);
        closeTimeout = undefined;
      }
    };
    const isInsideGroup = (target: EventTarget | null) => {
      if (!(target instanceof Node)) {
        return false;
      }

      for (const popover of group.popovers) {
        if (popover.contains(target)) {
          return true;
        }
      }

      return false;
    };
    const closeOpenSubmenu = () => {
      closeTimeout = undefined;

      if (pointerPosition && typeof document.elementFromPoint === "function") {
        const pointerTarget = document.elementFromPoint(
          pointerPosition.x,
          pointerPosition.y
        );
        if (isInsideGroup(pointerTarget)) {
          return;
        }
      }

      const state = rootMenuStateRef.current;
      const openSubmenuKey = state?.expandedKeysStack[0];
      if (state && openSubmenuKey != null) {
        const activeElement = document.activeElement;
        const openSubmenuTrigger = group.rootPopover?.querySelector<HTMLElement>(
          '[role="menuitem"][aria-expanded="true"]'
        );
        const shouldRestoreFocus =
          activeElement instanceof HTMLElement &&
          isInsideGroup(activeElement) &&
          !group.rootPopover?.contains(activeElement);

        state.closeSubmenu(openSubmenuKey, 0);
        if (shouldRestoreFocus) {
          openSubmenuTrigger?.focus({ preventScroll: true });
        }
      }
    };
    const handlePointerOver = (event: PointerEvent) => {
      if (event.pointerType === "mouse" && isInsideGroup(event.target)) {
        cancelClose();
      }
    };
    const handlePointerOut = (event: PointerEvent) => {
      if (
        event.pointerType !== "mouse" ||
        !isInsideGroup(event.target) ||
        isInsideGroup(event.relatedTarget)
      ) {
        return;
      }

      pointerPosition = { x: event.clientX, y: event.clientY };
      cancelClose();
      closeTimeout = setTimeout(closeOpenSubmenu, motionDuration.submenuCloseDelay);
    };

    document.addEventListener("pointerover", handlePointerOver, true);
    document.addEventListener("pointerout", handlePointerOut, true);

    return () => {
      cancelClose();
      document.removeEventListener("pointerover", handlePointerOver, true);
      document.removeEventListener("pointerout", handlePointerOut, true);
    };
  }, [group, isEnabled, isRootMenuOpen]);
}

const menuAnimationClasses = (
  animation: "anchor" | "fade" | "in-place" | "none",
  state: { isEntering: boolean; isExiting: boolean }
) =>
  cx(
    animation === "none" || animation === "in-place"
      ? menuPopoverStaticClasses
      : animation === "fade"
        ? menuPopoverFadeClasses
        : menuPopoverClasses,
    state.isEntering &&
      (animation === "none" || animation === "in-place"
        ? undefined
        : animation === "fade"
          ? menuPopoverFadeEnteringClasses
          : menuPopoverEnteringClasses),
    state.isExiting &&
      (animation === "none"
        ? menuPopoverStaticExitingClasses
        : animation === "in-place"
          ? menuPopoverInPlaceExitingClasses
          : animation === "fade"
            ? menuPopoverFadeExitingClasses
            : menuPopoverExitingClasses)
  );

const SelectionAlignedMenuPopover = forwardRef<
  HTMLDivElement,
  MenuPopoverProps & { selectionAlign: MenuPopoverSelectionAlignment }
>(function SelectionAlignedMenuPopover(
  {
    animation = "auto",
    children,
    className,
    offset,
    placement = "bottom start",
    selectionAlign,
    ...props
  },
  ref
) {
  const rootMenuState = useContext(RootMenuTriggerStateContext);
  // Menus open from MenuTrigger; a DialogTrigger (or a controlled popover)
  // reports through the overlay state instead, so the alignment math runs for
  // both hosts.
  const overlayState = useContext(OverlayTriggerStateContext);
  const isOpen = props.isOpen ?? rootMenuState?.isOpen ?? overlayState?.isOpen ?? false;
  const popoverElementRef = useRef<HTMLDivElement | null>(null);
  const popoverRef = useMemo(() => mergeRefs(ref, popoverElementRef), [ref]);
  const resolvedAnimation = animation === "auto" ? "anchor" : animation;
  const size = selectionAlign.size ?? "sm";
  const aligned = useSelectionAlignedPopover({
    chromeBorderWidth: borderWidth["0-5"],
    isOpen,
    items: selectionAlign.items,
    offset: typeof offset === "number" ? offset : undefined,
    rowHeight: selectionAlign.rowHeight ?? menuSelectionRowHeight,
    selectedIndex: selectionAlign.selectedIndex,
    size,
    triggerRef: selectionAlign.triggerRef,
  });

  useEffect(() => {
    if (!isOpen) return;
    // Land keyboard focus on the checked row that sits over the trigger, the
    // way macOS highlights the row the pointer is already resting on.
    const frame = requestAnimationFrame(() => {
      const checked = popoverElementRef.current?.querySelector<HTMLElement>(
        '[data-slot="menu-item"][aria-checked="true"]'
      );
      checked?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [isOpen]);

  return (
    <AriaPopover
      {...props}
      ref={popoverRef}
      {...aligned.popoverDataProps}
      containerPadding={aligned.popoverPositionProps.containerPadding}
      crossOffset={aligned.popoverPositionProps.crossOffset}
      {...definedProps({ maxHeight: aligned.popoverPositionProps.maxHeight })}
      offset={aligned.popoverPositionProps.offset}
      placement={placement}
      shouldFlip={false}
      className={(state) =>
        cx(
          "z-50 w-max min-w-[var(--trigger-width)] max-w-[calc(100vw-(var(--spacing-lg)*2))] overflow-hidden",
          menuSurfaceClasses,
          aligned.maxHeightClassName,
          menuAnimationClasses(resolvedAnimation, state),
          className
        )
      }
      data-animation={resolvedAnimation}
      data-slot="menu-popover"
    >
      <ScrollArea
        ref={aligned.scrollViewportRef}
        className="max-h-[inherit]"
        contentClassName="min-w-full"
        contentStyle={{
          paddingBottom: `${aligned.contentPaddingBottom}px`,
          paddingTop: `${aligned.contentPaddingTop}px`,
        }}
        edgeBlur={{ endSize: spacing["3xl"], startSize: spacing["3xl"] }}
        edgeEffect={aligned.contentRevealMode === "full" ? "none" : "blur"}
        scrollbar={false}
        viewportClassName="max-h-[inherit]"
        viewportProps={{ onPointerMove: aligned.revealFromPointer, tabIndex: -1 }}
      >
        {typeof children === "function" ? null : children}
      </ScrollArea>
      <SelectionAlignedRevealIndicator onReveal={aligned.revealAllContent} />
    </AriaPopover>
  );
});

/**
 * React Aria revives a popover that opens again during its exit animation
 * instead of mounting it anew, so the menu's `autoFocus` never runs. Keys then
 * reach whatever the opening press focused, and Escape cannot close the menu.
 * A revived popover gets fresh contents, exactly like any other open.
 */
function RevivedPopoverContents({
  children,
  isExiting,
}: {
  children: ReactNode;
  isExiting: boolean;
}) {
  const [revivals, setRevivals] = useState(0);
  const [wasExiting, setWasExiting] = useState(isExiting);
  if (isExiting !== wasExiting) {
    setWasExiting(isExiting);
    if (!isExiting) setRevivals((count) => count + 1);
  }
  return <Fragment key={revivals}>{children}</Fragment>;
}

const AnchorMenuPopover = forwardRef<HTMLDivElement, MenuPopoverProps>(
  function AnchorMenuPopover(
    {
      animation = "auto",
      children,
      className,
      closeSubmenusOnPointerLeave = false,
      dismissControlledNonModalOnInteractOutside = false,
      offset = spacing.xs,
      placement,
      selectionAlign: _selectionAlign,
      ...props
    },
    ref
  ) {
    const inheritedGroup = useContext(MenuPopoverGroupContext);
    const popoverContext = useSlottedContext(PopoverContext, props.slot);
    const resolvedAnimation =
      animation === "auto"
        ? (props.trigger ?? popoverContext?.trigger) === "SubmenuTrigger"
          ? "fade"
          : "anchor"
        : animation;
    const ownedGroup = useRef<MenuPopoverGroup>({
      popovers: new Set(),
      rootPopover: null,
    }).current;
    const interactionRef = useRef<HTMLDivElement | null>(null);
    const group = closeSubmenusOnPointerLeave ? ownedGroup : inheritedGroup;
    const handleKeyDownCapture = useCallback(
      (event: KeyboardEvent) => {
        if (!event.defaultPrevented && event.currentTarget instanceof HTMLElement) {
          preserveSubmenuTriggerFocus(event.currentTarget, event.key, group);
        }
      },
      [group]
    );
    const combinedRef = useMemo(() => mergeRefs(ref, interactionRef), [ref]);
    const popoverRef = useMenuPopoverRef(
      group,
      combinedRef,
      closeSubmenusOnPointerLeave,
      handleKeyDownCapture
    );
    useInteractOutside({
      isDisabled: !dismissControlledNonModalOnInteractOutside || props.isOpen !== true,
      onInteractOutside: () => props.onOpenChange?.(false),
      ref: interactionRef,
    });
    useCloseSubmenusOnPointerLeave(closeSubmenusOnPointerLeave, ownedGroup);

    const popover = (
      <AriaPopover
        {...props}
        ref={popoverRef}
        offset={offset}
        placement={placement ?? popoverContext?.placement ?? "bottom start"}
        className={(state) =>
          cx(menuAnimationClasses(resolvedAnimation, state), className)
        }
        data-animation={resolvedAnimation}
        data-slot="menu-popover"
      >
        {(values) => (
          <RevivedPopoverContents isExiting={values.isExiting}>
            {typeof children === "function" ? children(values) : children}
          </RevivedPopoverContents>
        )}
      </AriaPopover>
    );

    return closeSubmenusOnPointerLeave ? (
      <MenuPopoverGroupContext.Provider value={ownedGroup}>
        {popover}
      </MenuPopoverGroupContext.Provider>
    ) : (
      popover
    );
  }
);

export const MenuPopover = forwardRef<HTMLDivElement, MenuPopoverProps>(
  function MenuPopover(props, ref) {
    return props.selectionAlign ? (
      <SelectionAlignedMenuPopover
        {...props}
        ref={ref}
        selectionAlign={props.selectionAlign}
      />
    ) : (
      <AnchorMenuPopover {...props} ref={ref} />
    );
  }
);
