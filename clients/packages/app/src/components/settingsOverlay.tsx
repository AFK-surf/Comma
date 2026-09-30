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
import {
  useCanGoBack,
  useNavigate,
  useRouter,
  useRouterState,
} from "@tanstack/react-router";
import { isSettingsPath } from "./productShellPaths";

export type CommaSettingsOverlayValue = {
  /** The settings modal is showing over the current surface. */
  open: boolean;
  openSettings: () => void;
  closeSettings: () => void;
};

const CommaSettingsOverlayContext = createContext<CommaSettingsOverlayValue>({
  open: false,
  openSettings: () => {},
  closeSettings: () => {},
});

/**
 * Settings is a modal, not a place: opening it leaves the product route (and
 * everything it has in flight) exactly where it was. `/settings` stays a
 * location so a deep link still lands on it; closing that one navigates back
 * to where the user came from, or Home when there is nothing to go back to.
 */
export function CommaSettingsOverlayProvider({ children }: { children: ReactNode }) {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const canGoBack = useCanGoBack();
  const navigate = useNavigate();
  const router = useRouter();
  const [requested, setRequested] = useState(false);
  const routed = isSettingsPath(pathname);
  const openSettings = useCallback(() => setRequested(true), []);
  // A modal raised over one route does not follow the user to the next: a
  // navigation from inside it (the command palette opening a Task) lands on
  // that Task with Settings gone, as leaving the routed form of Settings does.
  const openedAtPathname = useRef(pathname);
  if (!requested) openedAtPathname.current = pathname;
  useEffect(() => {
    if (requested && pathname !== openedAtPathname.current) setRequested(false);
  }, [pathname, requested]);
  const closeSettings = useCallback(() => {
    setRequested(false);
    if (!routed) return;
    if (canGoBack) {
      router.history.back();
      return;
    }
    void navigate({ to: "/" });
  }, [canGoBack, navigate, routed, router.history]);
  const value = useMemo<CommaSettingsOverlayValue>(
    () => ({ closeSettings, open: requested || routed, openSettings }),
    [closeSettings, openSettings, requested, routed]
  );

  return (
    <CommaSettingsOverlayContext.Provider value={value}>
      {children}
    </CommaSettingsOverlayContext.Provider>
  );
}

export function useCommaSettingsOverlay() {
  return useContext(CommaSettingsOverlayContext);
}
