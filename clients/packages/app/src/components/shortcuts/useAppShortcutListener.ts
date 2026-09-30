import { useWindowHistory } from "../WindowBar";
import {
  readCollapsedHomeRails,
  toggleCollapsedHomeRail,
} from "../home/homeRailCollapse";
import { useApplicationMenu } from "../application-menu/useApplicationMenu";
import { formatAppKeybinding } from "@comma/ui";
import {
  APP_KEYBINDING_SEQUENCE_TIMEOUT_MS,
  isEditableTarget,
  matchesAppKeyStroke,
  type AppKeyCode,
} from "@comma/ui";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { useCallback, useEffect, useRef } from "react";
import { useChatSidebar } from "../chat-sidebar/ChatSidebarContext";
import { useCommandPalette } from "../search/CommandPaletteContext";
import { driveSynchronicityAvailable } from "../drive/driveSynchronicityBackend";
import { useCommaSettingsOverlay } from "../settingsOverlay";
import { useCommaSidebar } from "../sidebar/SidebarContext";
import type { AppShortcutId } from "./appShortcutRegistry";
import { useCommaAppShortcuts } from "./commaAppShortcuts";

type SequenceCandidate = {
  id: AppShortcutId;
  codes: readonly AppKeyCode[];
};

// Open menus and select lists take typed keys as type-to-select.
const typeSelectPopoverSelector =
  '[data-slot="dropdown-popover"], [data-slot="menu-popover"]';

type SequenceState = {
  candidates: readonly SequenceCandidate[];
  index: number;
};

type NavigationShortcutId =
  | "go-settings"
  | "go-comma-assistant"
  | "go-search"
  | "go-inbox"
  | "go-drive"
  | "go-tasks"
  | "go-plugins"
  | "history-back"
  | "history-forward";

type ShellShortcutId = "toggle-left-sidebar" | "toggle-right-sidebar";

const navigationShortcutIds = [
  "go-settings",
  "go-comma-assistant",
  "go-search",
  "go-inbox",
  "go-drive",
  "go-tasks",
  "go-plugins",
  "history-back",
  "history-forward",
] as const satisfies readonly NavigationShortcutId[];

const shellShortcutIds = [
  "toggle-left-sidebar",
  "toggle-right-sidebar",
] as const satisfies readonly ShellShortcutId[];

const productShortcutIds = [
  ...navigationShortcutIds,
  ...shellShortcutIds,
] as const satisfies readonly AppShortcutId[];

// Drive has no page to open where its synchronicity node does not run.
const webProductShortcutIds = productShortcutIds.filter((id) => id !== "go-drive");

function availableProductShortcutIds(): readonly AppShortcutId[] {
  return driveSynchronicityAvailable() ? productShortcutIds : webProductShortcutIds;
}

const navigationShortcutIdSet: ReadonlySet<AppShortcutId> = new Set(
  navigationShortcutIds
);

const navigationTargets: Partial<
  Record<
    NavigationShortcutId,
    "/" | "/settings" | "/inbox" | "/drive" | "/tasks" | "/plugins"
  >
> = {
  "go-comma-assistant": "/",
  "go-inbox": "/inbox",
  "go-drive": "/drive",
  "go-tasks": "/tasks",
  "go-plugins": "/plugins",
};

function useScopedAppShortcutListener(
  ids: readonly AppShortcutId[],
  runShortcut: (id: AppShortcutId) => void
) {
  const { bindings } = useCommaAppShortcuts();
  const sequenceRef = useRef<SequenceState | undefined>(undefined);
  const sequenceTimerRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    const clearSequence = () => {
      sequenceRef.current = undefined;
      if (sequenceTimerRef.current !== undefined) {
        window.clearTimeout(sequenceTimerRef.current);
        sequenceTimerRef.current = undefined;
      }
    };

    const armSequenceTimeout = () => {
      if (sequenceTimerRef.current !== undefined) {
        window.clearTimeout(sequenceTimerRef.current);
      }
      sequenceTimerRef.current = window.setTimeout(() => {
        sequenceRef.current = undefined;
        sequenceTimerRef.current = undefined;
      }, APP_KEYBINDING_SEQUENCE_TIMEOUT_MS);
    };

    const run = (id: AppShortcutId) => {
      clearSequence();
      runShortcut(id);
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.repeat) return;
      const shortcutControl =
        event.target instanceof HTMLElement
          ? event.target.closest(
              '[data-slot="settings-shortcut"], [data-slot="settings-keybinding"]'
            )
          : null;

      // Search is a global command surface. Its chord must also toggle while
      // focus is inside a composer, the palette input, or an idle shortcut
      // control. A shortcut control that is actively recording stops the event
      // before it reaches this window listener.
      if (ids.includes("go-search")) {
        const searchBinding = bindings["go-search"];
        if (
          searchBinding?.kind === "chord" &&
          matchesAppKeyStroke(searchBinding.stroke, event)
        ) {
          event.preventDefault();
          run("go-search");
          return;
        }
      }
      if (shortcutControl) return;
      if (isEditableTarget(event.target)) return;

      const unmodified =
        !event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey;
      // Letters there pick an option by name, such as a font by its family,
      // so they must not also run a letter sequence.
      if (
        unmodified &&
        event.target instanceof Element &&
        event.target.closest(typeSelectPopoverSelector)
      ) {
        return;
      }
      const activeSequence = sequenceRef.current;
      if (activeSequence) {
        const candidates = unmodified
          ? activeSequence.candidates.filter(
              ({ codes }) => codes[activeSequence.index] === event.code
            )
          : [];
        if (candidates.length > 0) {
          event.preventDefault();
          const nextIndex = activeSequence.index + 1;
          const completed = candidates.find(({ codes }) => nextIndex >= codes.length);
          if (completed) {
            run(completed.id);
            return;
          }
          sequenceRef.current = { candidates, index: nextIndex };
          armSequenceTimeout();
          return;
        }
        clearSequence();
      }

      for (const id of ids) {
        if (id === "go-search") continue;
        const binding = bindings[id];
        if (!binding || binding.kind !== "chord") continue;
        if (!matchesAppKeyStroke(binding.stroke, event)) continue;
        event.preventDefault();
        run(id);
        return;
      }

      if (!unmodified) return;
      const candidates = ids.flatMap<SequenceCandidate>((id) => {
        const binding = bindings[id];
        if (!binding || binding.kind !== "sequence") return [];
        if (binding.codes[0] !== event.code) return [];
        return [{ id, codes: binding.codes }];
      });
      if (candidates.length === 0) return;

      event.preventDefault();
      sequenceRef.current = { candidates, index: 1 };
      armSequenceTimeout();
    };

    window.addEventListener("keydown", onKeyDown);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      clearSequence();
    };
  }, [bindings, ids, runShortcut]);
}

function useAppNavigationShortcutRunner() {
  const navigate = useNavigate();
  const router = useRouter();
  const { openSettings } = useCommaSettingsOverlay();
  const { toggle: toggleCommandPalette } = useCommandPalette();
  return useCallback(
    (id: AppShortcutId) => {
      if (id === "go-settings") {
        openSettings();
        return;
      }
      if (id === "go-search") {
        toggleCommandPalette();
        return;
      }
      const target = navigationTargets[id as NavigationShortcutId];
      if (target) {
        if (router.state.location.pathname === target) return;
        void navigate({ to: target });
        return;
      }
      if (id === "history-back") {
        router.history.back();
        return;
      }
      if (id === "history-forward") {
        router.history.forward();
      }
    },
    [
      navigate,
      openSettings,
      router.history,
      router.state.location.pathname,
      toggleCommandPalette,
    ]
  );
}

function useAppShellShortcutRunner() {
  const { toggleCollapsed } = useCommaSidebar();
  const { toggleActive } = useChatSidebar();
  return useCallback(
    (id: AppShortcutId) => {
      if (id === "toggle-left-sidebar") {
        toggleCollapsed();
        return;
      }
      if (id === "toggle-right-sidebar") {
        toggleActive();
      }
    },
    [toggleActive, toggleCollapsed]
  );
}

export function useAppProductShortcutListener() {
  const runNavigationShortcut = useAppNavigationShortcutRunner();
  const runShellShortcut = useAppShellShortcutRunner();
  const runShortcut = useCallback(
    (id: AppShortcutId) => {
      if (navigationShortcutIdSet.has(id)) {
        runNavigationShortcut(id);
        return;
      }
      runShellShortcut(id);
    },
    [runNavigationShortcut, runShellShortcut]
  );

  const { bindings } = useCommaAppShortcuts();
  const navigate = useNavigate();
  const sidebar = useCommaSidebar();
  const rightSidebar = useChatSidebar();
  const history = useWindowHistory();
  useApplicationMenu([
    ...productShortcutIds.map((id) => {
      const binding = bindings[id];
      const key = binding?.kind === "chord" ? binding.stroke : undefined;
      const keyNames: Record<string, string> = {
        Comma: ",",
        BracketLeft: "[",
        BracketRight: "]",
      };
      const accelerator = key
        ? [
            key.modifiers.meta && "Super",
            key.modifiers.control && "Control",
            key.modifiers.alt && "Alt",
            key.modifiers.shift && "Shift",
            keyNames[key.code] ?? key.code.replace(/^Key|^Digit/, ""),
          ]
            .filter(Boolean)
            .join("+")
        : undefined;
      return {
        id,
        enabled:
          (id !== "history-back" || history.canGoBack) &&
          (id !== "history-forward" || history.canGoForward),
        run: () => runShortcut(id),
        ...(accelerator ? { accelerator } : {}),
        ...(binding?.kind === "sequence"
          ? { shortcutLabel: formatAppKeybinding(binding).replaceAll(" ", " → ") }
          : {}),
        ...(id === "toggle-left-sidebar" ? { checked: !sidebar.collapsed } : {}),
        ...(id === "toggle-right-sidebar" ? { checked: rightSidebar.isOpen } : {}),
      };
    }),
    {
      id: "go-routines",
      enabled: true,
      run: () => {
        if (readCollapsedHomeRails().greet) toggleCollapsedHomeRail("greet");
        return navigate({ to: "/" });
      },
    },
    {
      id: "go-shortcuts",
      enabled: true,
      run: () => {
        window.location.hash = "/settings?category=keyboard-shortcuts";
      },
    },
    {
      id: "go-recording-settings",
      enabled: true,
      run: () => {
        window.location.hash = "/settings?category=meeting";
      },
    },
  ]);
  useScopedAppShortcutListener(availableProductShortcutIds(), runShortcut);
}

export function AppProductShortcutListener() {
  useAppProductShortcutListener();
  return null;
}
