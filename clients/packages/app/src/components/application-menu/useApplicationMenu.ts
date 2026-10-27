import { useCommaLocale } from "@comma/i18n/react";
import {
  getNativeBridge,
  type ApplicationMenuCommand,
  type ApplicationMenuItems,
} from "@comma/native-bridge";
import { useEffect, useRef, useSyncExternalStore } from "react";
import { toast } from "@comma/ui/components/toast";
import {
  isOnboardingOpen,
  subscribeOnboardingOpen,
} from "../onboarding/onboardingPresence";

type MenuAction = ApplicationMenuItems[number] & { run: () => unknown };
const owners = new Map<symbol, readonly MenuAction[]>();
let locale: "en" | "zh-CN" = "en";
let unsubscribe: (() => void) | undefined;
let publishQueued = false;
// The commands enabled now, for the command palette (one per id, as the menu
// keeps them); a new array each time the owners change.
let enabledCommands: readonly ApplicationMenuCommand[] = [];
const enabledListeners = new Set<() => void>();
function ownersChanged() {
  const enabled = new Map<ApplicationMenuCommand, boolean>();
  for (const group of owners.values())
    for (const action of group)
      enabled.set(action.id, action.enabled || (enabled.get(action.id) ?? false));
  enabledCommands = [...enabled].flatMap(([id, on]) => (on ? [id] : []));
  for (const listener of enabledListeners) listener();
}
function publish() {
  if (publishQueued) return;
  publishQueued = true;
  queueMicrotask(() => {
    publishQueued = false;
    publishCurrentOwners();
  });
}

function publishCurrentOwners() {
  const bridge = getNativeBridge();
  if (bridge.platform !== "electron") return;
  const actions = new Map<ApplicationMenuCommand, MenuAction>();
  for (const group of owners.values())
    for (const action of group) {
      if (action.enabled || !actions.get(action.id)?.enabled)
        actions.set(action.id, action);
    }
  // While the first-launch onboarding is open, every command stays listed but
  // unavailable, accelerators included: each acts on a surface the onboarding
  // covers. The menu's system items (Edit, Close, Minimize, Quit) are not
  // published here and keep working.
  const onboardingOpen = isOnboardingOpen();
  void bridge.applicationMenu
    .update({
      locale,
      items: [...actions.values()].map(({ run: _run, ...item }) => ({
        ...item,
        enabled: item.enabled && !onboardingOpen,
      })),
    })
    .catch(console.error);
}

/** Mounted surfaces own commands; unmount withdraws them from the native menu. */
export function useApplicationMenu(actions: readonly MenuAction[]) {
  const currentLocale = useCommaLocale();
  const owner = useRef(Symbol("application-menu"));
  const current = useRef(actions);
  current.current = actions;
  const presentation = JSON.stringify(actions.map(({ run: _run, ...item }) => item));
  useEffect(() => {
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron" || current.current.length === 0) return;
    locale = currentLocale;
    const key = owner.current;
    if (!unsubscribe) {
      const stopCommands = bridge.applicationMenu.onCommand(runApplicationMenuCommand);
      const stopOnboarding = subscribeOnboardingOpen(publish);
      unsubscribe = () => {
        stopCommands();
        stopOnboarding();
      };
    }
    owners.set(
      key,
      current.current.map((item) => ({
        ...item,
        run: () => current.current.find((candidate) => candidate.id === item.id)?.run(),
      }))
    );
    publish();
    ownersChanged();
    return () => {
      owners.delete(key);
      publish();
      ownersChanged();
      if (!owners.size) {
        unsubscribe?.();
        unsubscribe = undefined;
      }
    };
  }, [presentation, currentLocale]);
}

/**
 * The application menu's commands enabled now, as mounted surfaces own them
 * (none outside the desktop app): what the command palette offers of them.
 */
export function useEnabledApplicationMenuCommands(): readonly ApplicationMenuCommand[] {
  return useSyncExternalStore(
    (listener) => {
      enabledListeners.add(listener);
      return () => enabledListeners.delete(listener);
    },
    () => enabledCommands,
    () => enabledCommands
  );
}

/** Runs a menu command as choosing it in the menu does: its latest enabled owner's. */
export function runApplicationMenuCommand(id: ApplicationMenuCommand) {
  if (isOnboardingOpen()) return;
  const action = [...owners.values()]
    .flat()
    .findLast((item) => item.id === id && item.enabled);
  if (action)
    void Promise.resolve()
      .then(action.run)
      .catch((error: unknown) => {
        toast.error(error instanceof Error ? error.message : "Menu action failed");
      });
}
