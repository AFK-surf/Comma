import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { appKeybindingKeycaps, cx, formatAppKeybinding } from "@comma/ui";
import { useCanGoBack, useRouter } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { useIsGuestSession } from "./auth-context";
import { GuestSignUpBanner } from "./GuestSignUpBanner";
import { ShellIconButton } from "./ShellIconButton";
import { ChatSidebarToggle } from "./chat-sidebar/ChatSidebar";
import { useCommandPalette } from "./search/CommandPaletteContext";
import { RecentTasksMenu } from "./sidebar/RecentTasksMenu";
import { useAppShortcutBinding } from "./shortcuts/commaAppShortcuts";

/**
 * The row across the top of the window frame: the native traffic lights'
 * slot and history on the left; the recent-tasks menu and the Chat Sidebar
 * toggle on the right; the search hint between them. The two flanks are equal
 * grid columns (styles.css) so the hint sits on the window's centre line. The
 * row itself is the window's drag surface; every control in it opts out.
 */
export function WindowBar() {
  const messages = useCommaMessages();
  const { canGoBack, canGoForward, goBack, goForward } = useWindowHistory();
  const backShortcut = useAppShortcutBinding("history-back");
  const forwardShortcut = useAppShortcutBinding("history-forward");
  const hasTrafficLights = useHasTrafficLights();
  const guest = useIsGuestSession();

  return (
    <div
      className={cx(
        "comma-window-bar comma-window-titlebar-region grid shrink-0 items-center gap-lg pb-xs pr-lg pt-sm",
        hasTrafficLights ? "pl-sm" : "pl-lg"
      )}
      data-guest={guest ? "true" : undefined}
      data-testid="comma-window-bar"
    >
      {/* The flank keeps the lights' 32px row height on every platform, so the
          bar stays 42px tall with or without them. */}
      <div className="comma-window-bar-leading flex h-8 shrink-0 items-center gap-lg">
        {hasTrafficLights ? (
          // macOS paints the traffic lights into this slot (window-options.ts
          // centres them on the row).
          <div
            aria-hidden="true"
            className="comma-native-window-controls h-8 w-16 shrink-0"
            data-testid="comma-native-window-controls"
          />
        ) : null}
        <div className="comma-window-history flex shrink-0 items-center gap-xs">
          <ShellIconButton
            className="comma-icon-press"
            disabled={!canGoBack}
            icon="arrow-left"
            iconClassName="comma-icon-press-back"
            label={messages.shell_back()}
            onClick={goBack}
            {...(backShortcut ? { shortcut: appKeybindingKeycaps(backShortcut) } : {})}
          />
          <ShellIconButton
            className="comma-icon-press"
            disabled={!canGoForward}
            icon="arrow-right"
            iconClassName="comma-icon-press-forward"
            label={messages.shell_forward()}
            onClick={goForward}
            {...(forwardShortcut
              ? { shortcut: appKeybindingKeycaps(forwardShortcut) }
              : {})}
          />
        </div>
      </div>
      {guest ? <GuestSignUpBanner /> : <WindowBarSearch />}
      <div className="comma-window-bar-trailing flex shrink-0 items-center justify-end gap-xs">
        {guest ? null : <RecentTasksMenu />}
        {guest ? null : <ChatSidebarToggle />}
      </div>
    </div>
  );
}

// Only the macOS Electron window paints traffic lights into the row
// (window-options.ts), and macOS hides them while the window is full screen;
// without them history leads at the trailing flank's inset.
function useHasTrafficLights() {
  const bridge = getNativeBridge();
  const macWindow = bridge.platform === "electron" && bridge.os === "macos";
  const [fullScreen, setFullScreen] = useState(false);

  useEffect(() => {
    if (!macWindow) return;
    return bridge.surfaces.windowFullScreen.subscribe((snapshot) =>
      setFullScreen(snapshot.fullScreen)
    );
  }, [bridge, macWindow]);

  return macWindow && !fullScreen;
}

// The hint is the pointer path to the command palette; the palette's own
// chord (the go-search binding it names) is the keyboard one.
function WindowBarSearch() {
  const messages = useCommaMessages();
  const { open: openCommandPalette } = useCommandPalette();
  const searchShortcut = useAppShortcutBinding("go-search");
  const hint = searchShortcut
    ? messages.shell_search_hint({ shortcut: formatAppKeybinding(searchShortcut) })
    : messages.nav_search();

  return (
    <div className="comma-window-bar-search-slot flex min-w-0 items-center justify-center px-md">
      <AriaButton
        className="comma-window-bar-search flex w-full min-w-0 max-w-[var(--comma-window-bar-search-max-width)] items-center justify-center rounded-full border-[0.5px] border-primary bg-main-panel-bg px-xs py-xs text-xs font-normal text-placeholder shadow-xs outline-none transition-colors duration-[50ms] hover:text-quaternary focus-visible:shadow-focus-gray"
        data-testid="comma-window-bar-search"
        onPress={openCommandPalette}
      >
        <span className="truncate">{hint}</span>
      </AriaButton>
    </div>
  );
}

export function useWindowHistory() {
  const router = useRouter();
  const canGoBack = useCanGoBack();
  const [canGoForward, setCanGoForward] = useState(
    () => browserNavigation()?.canGoForward ?? false
  );

  useEffect(() => {
    const navigation = browserNavigation();
    if (navigation) {
      const updateCanGoForward = () => setCanGoForward(navigation.canGoForward);

      navigation.addEventListener("currententrychange", updateCanGoForward);
      updateCanGoForward();

      return () =>
        navigation.removeEventListener("currententrychange", updateCanGoForward);
    }

    let currentIndex = historyIndex(router.history.location.state);
    let maximumIndex = currentIndex;

    return router.history.subscribe(({ action, location }) => {
      currentIndex = historyIndex(location.state);
      maximumIndex =
        // A new navigation discards the browser's forward branch.
        action.type === "PUSH" ? currentIndex : Math.max(maximumIndex, currentIndex);

      setCanGoForward(currentIndex < maximumIndex);
    });
  }, [router.history]);

  return {
    canGoBack,
    canGoForward,
    goBack: () => router.history.back(),
    goForward: () => router.history.forward(),
  };
}

function browserNavigation() {
  return typeof window === "undefined" ? undefined : window.navigation;
}

function historyIndex(state: { __TSR_index: number }) {
  // oxlint-disable-next-line no-underscore-dangle -- TanStack Router owns this history index.
  return state.__TSR_index;
}
