import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { ChatConsumerBoundary } from "../chat/ChatProvider";
import { AppCommandPalette } from "./AppCommandPalette";

type CommandPaletteContextValue = {
  /**
   * Takes the palette element over from the provider for as long as the
   * returned release stands. A modal that hosts it renders `paletteElement`
   * inside its own subtree, so the palette's focus scope nests inside the
   * modal's instead of standing beside it and losing the input focus.
   */
  claimPaletteHost: () => () => void;
  close: () => void;
  isOpen: boolean;
  open: () => void;
  paletteElement: ReactNode;
  toggle: () => void;
};

const CommandPaletteContext = createContext<CommandPaletteContextValue | null>(null);

export function CommandPaletteProvider({ children }: { children: ReactNode }) {
  const [isOpen, setOpen] = useState(false);
  const focusBeforeOpen = useRef<HTMLElement | null>(null);
  const open = useCallback(() => {
    focusBeforeOpen.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setOpen(true);
  }, []);
  const close = useCallback(() => {
    setOpen(false);
    const target = focusBeforeOpen.current;
    focusBeforeOpen.current = null;
    window.setTimeout(() => {
      if (target?.isConnected) target.focus({ preventScroll: true });
    });
  }, []);
  const closeAfterAction = useCallback(() => {
    focusBeforeOpen.current = null;
    setOpen(false);
  }, []);
  const toggle = useCallback(() => {
    if (isOpen) close();
    else open();
  }, [close, isOpen, open]);
  const handleOpenChange = useCallback(
    (nextOpen: boolean) => {
      if (nextOpen) open();
      else close();
    },
    [close, open]
  );
  const [hostCount, setHostCount] = useState(0);
  const claimPaletteHost = useCallback(() => {
    setHostCount((count) => count + 1);
    return () => setHostCount((count) => count - 1);
  }, []);
  const paletteElement = useMemo(
    () => (
      <ChatConsumerBoundary>
        <AppCommandPalette
          onActionClose={closeAfterAction}
          onOpenChange={handleOpenChange}
          open={isOpen}
        />
      </ChatConsumerBoundary>
    ),
    [closeAfterAction, handleOpenChange, isOpen]
  );
  const value = useMemo(
    () => ({ claimPaletteHost, close, isOpen, open, paletteElement, toggle }),
    [claimPaletteHost, close, isOpen, open, paletteElement, toggle]
  );

  return (
    <CommandPaletteContext.Provider value={value}>
      {children}
      {hostCount === 0 ? paletteElement : null}
    </CommandPaletteContext.Provider>
  );
}

export function useCommandPalette() {
  const context = useContext(CommandPaletteContext);
  if (!context) {
    throw new Error("useCommandPalette must be used within CommandPaletteProvider");
  }
  return context;
}

/** For surfaces that also render without a palette, such as Settings in isolation. */
export function useOptionalCommandPalette() {
  return useContext(CommandPaletteContext);
}
