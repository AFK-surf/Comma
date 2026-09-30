import {
  createContext,
  useContext,
  useId,
  useLayoutEffect,
  useState,
  type ContextType,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";
import {
  MenuContext,
  OverlayTriggerStateContext,
  PopoverContext,
} from "react-aria-components";

type ActiveSubmenu = {
  id: string;
  children: ReactNode;
  menu: ContextType<typeof MenuContext>;
  overlay: ContextType<typeof OverlayTriggerStateContext>;
  popover: ContextType<typeof PopoverContext>;
};

const SharedSubmenuContext = createContext<Dispatch<
  SetStateAction<ActiveSubmenu | null>
> | null>(null);

/**
 * React Aria owns each trigger's navigation and focus. Move the active trigger's
 * contexts to one surface so sibling switches update its anchor without remounting.
 */
export function SharedSubmenuScope({ children }: { children: ReactNode }) {
  const [active, setActive] = useState<ActiveSubmenu | null>(null);
  return (
    <SharedSubmenuContext.Provider value={setActive}>
      {children}
      {active && (
        <MenuContext.Provider value={active.menu}>
          <OverlayTriggerStateContext.Provider value={active.overlay}>
            <PopoverContext.Provider value={active.popover}>
              {active.children}
            </PopoverContext.Provider>
          </OverlayTriggerStateContext.Provider>
        </MenuContext.Provider>
      )}
    </SharedSubmenuContext.Provider>
  );
}

/** Use as the popover child of a SubmenuTrigger inside SharedSubmenuScope. */
export function SharedSubmenu({ children }: { children: ReactNode }) {
  const publish = useContext(SharedSubmenuContext);
  const menu = useContext(MenuContext);
  const overlay = useContext(OverlayTriggerStateContext);
  const popover = useContext(PopoverContext);
  const id = useId();

  useLayoutEffect(() => {
    if (!publish) return;
    if (overlay?.isOpen) {
      publish({ id, children, menu, overlay, popover });
    } else {
      publish((active) => (active?.id === id ? null : active));
    }
  }, [publish, id, children, menu, overlay, popover]);

  useLayoutEffect(
    () => () => publish?.((active) => (active?.id === id ? null : active)),
    [publish, id]
  );

  return null;
}
