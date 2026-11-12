import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { uiClock } from "@comma/ui/clock";
import { useIsGuestSession } from "../auth-context";
import { ChatConsumerBoundary } from "../chat/ChatProvider";
import type { ChatSidebarActions } from "../chat-sidebar/ChatSidebarContext";
import type { AppShortcutId } from "../shortcuts/appShortcutRegistry";
import { AppCommandPalette } from "./AppCommandPalette";

type AppShortcutRunner = (id: AppShortcutId) => void;
type FilePreviewOpener = ChatSidebarActions["openFilePreview"];

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
  /**
   * Lends the palette the shell's shortcut runner for as long as the returned
   * release stands. The shell owns the sidebars and Settings that its actions
   * drive, and they sit below this provider.
   */
  provideShortcutRunner: (run: AppShortcutRunner) => () => void;
  /**
   * Lends the palette the Chat Sidebar's file preview for as long as the
   * returned release stands, so a found file opens beside its Task. The
   * sidebar sits below this provider, in the product layout.
   */
  provideFilePreview: (open: FilePreviewOpener) => () => void;
  toggle: () => void;
};

const CommandPaletteContext = createContext<CommandPaletteContextValue | null>(null);

export function CommandPaletteProvider({ children }: { children: ReactNode }) {
  // The palette searches and opens Tasks, which a guest Session does not have:
  // it neither opens nor mounts its Task queries.
  const guest = useIsGuestSession();
  const [isOpen, setOpen] = useState(false);
  const focusBeforeOpen = useRef<HTMLElement | null>(null);
  const open = useCallback(() => {
    if (guest) return;
    focusBeforeOpen.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setOpen(true);
  }, [guest]);
  const close = useCallback(() => {
    setOpen(false);
    const target = focusBeforeOpen.current;
    focusBeforeOpen.current = null;
    uiClock.after(0, () => {
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
  const [shortcutRunner, setShortcutRunner] = useState<{ run: AppShortcutRunner }>();
  const provideShortcutRunner = useCallback((run: AppShortcutRunner) => {
    const entry = { run };
    setShortcutRunner(entry);
    return () =>
      setShortcutRunner((current) => (current === entry ? undefined : current));
  }, []);
  const [filePreview, setFilePreview] = useState<{ open: FilePreviewOpener }>();
  const provideFilePreview = useCallback((openPreview: FilePreviewOpener) => {
    const entry = { open: openPreview };
    setFilePreview(entry);
    return () => setFilePreview((current) => (current === entry ? undefined : current));
  }, []);
  const paletteElement = useMemo(
    () =>
      guest ? null : (
        <ChatConsumerBoundary>
          <AppCommandPalette
            onActionClose={closeAfterAction}
            onOpenChange={handleOpenChange}
            open={isOpen}
            {...(shortcutRunner ? { runShortcut: shortcutRunner.run } : {})}
            {...(filePreview ? { openFilePreview: filePreview.open } : {})}
          />
        </ChatConsumerBoundary>
      ),
    [closeAfterAction, filePreview, guest, handleOpenChange, isOpen, shortcutRunner]
  );
  const value = useMemo(
    () => ({
      claimPaletteHost,
      close,
      isOpen,
      open,
      paletteElement,
      provideFilePreview,
      provideShortcutRunner,
      toggle,
    }),
    [
      claimPaletteHost,
      close,
      isOpen,
      open,
      paletteElement,
      provideFilePreview,
      provideShortcutRunner,
      toggle,
    ]
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

/** Offers the palette's actions `run` while the calling surface is mounted. */
export function useProvideCommandPaletteShortcutRunner(run: AppShortcutRunner) {
  const { provideShortcutRunner } = useCommandPalette();
  useEffect(() => provideShortcutRunner(run), [provideShortcutRunner, run]);
}

/** Offers the palette the Chat Sidebar's file preview while the calling surface is mounted. */
export function useProvideCommandPaletteFilePreview(openPreview: FilePreviewOpener) {
  const { provideFilePreview } = useCommandPalette();
  useEffect(() => provideFilePreview(openPreview), [openPreview, provideFilePreview]);
}
