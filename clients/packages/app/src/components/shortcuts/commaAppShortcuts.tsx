import {
  appKeybindingsConflict,
  detectAppKeybindingPlatform,
  sameAppKeybinding,
  type AppKeybinding,
} from "@comma/ui";
import { type SideChatShortcutBinding } from "@comma/native-bridge";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  type ReactNode,
} from "react";
import { useOptionalCommaSideChatShortcut } from "../commaSideChatShortcut";
import { useCommaClientSettings } from "../commaClientSettings";
import { isElectronSideChatRuntime } from "../../runtime-side-chat/nativeSideChat";
import {
  appShortcutIds,
  createDefaultAppShortcutBindings,
  type AppShortcutBindings,
  type AppShortcutId,
  type AppShortcutPlatform,
} from "./appShortcutRegistry";
import {
  appBindingConflictsWithSideChatShortcut,
  findAppShortcutConflictForSideChat,
} from "./sideChatShortcutConflict";
import {
  appShortcutBindingsToOverrides,
  resolveAppShortcutBindings,
} from "./appShortcutSettings";

type CommaAppShortcutsContextValue = {
  bindings: AppShortcutBindings;
  defaultBindings: AppShortcutBindings;
  isDefault: boolean;
  resetAll: () => void;
  setBinding: (id: AppShortcutId, binding: AppKeybinding | null) => boolean;
  conflictFor: (
    id: AppShortcutId,
    binding: AppKeybinding | null
  ) => AppShortcutId | undefined;
};

const CommaAppShortcutsContext = createContext<CommaAppShortcutsContextValue | null>(
  null
);

const findConflict = (
  bindings: AppShortcutBindings,
  id: AppShortcutId,
  binding: AppKeybinding | null
) =>
  appShortcutIds.find(
    (otherId) => otherId !== id && appKeybindingsConflict(bindings[otherId], binding)
  );

const disableSideChatConflict = (
  bindings: AppShortcutBindings,
  ...shortcuts: Array<SideChatShortcutBinding | undefined>
) => {
  let next = bindings;
  for (const shortcut of shortcuts) {
    if (!shortcut) continue;
    const conflict = findAppShortcutConflictForSideChat(next, shortcut);
    if (conflict) next = { ...next, [conflict]: null };
  }
  return { bindings: next, changed: next !== bindings };
};

export function CommaAppShortcutsProvider({
  children,
  platform = detectAppKeybindingPlatform(),
}: {
  children: ReactNode;
  platform?: AppShortcutPlatform;
}) {
  const clientSettings = useCommaClientSettings();
  const sideChatShortcutContext = useOptionalCommaSideChatShortcut();
  const sideChatShortcut =
    isElectronSideChatRuntime() &&
    sideChatShortcutContext &&
    !sideChatShortcutContext.registrationPending
      ? sideChatShortcutContext.shortcut
      : undefined;
  const openCommaShortcut = isElectronSideChatRuntime()
    ? clientSettings.settings.openCommaShortcut
    : undefined;
  const defaults = useMemo(
    () => createDefaultAppShortcutBindings(platform),
    [platform]
  );
  const bindings = useMemo(
    () =>
      resolveAppShortcutBindings(
        defaults,
        clientSettings.settings.appShortcutOverrides
      ),
    [clientSettings.settings.appShortcutOverrides, defaults]
  );
  const bindingsRef = useRef(bindings);
  bindingsRef.current = bindings;
  const effectiveBindings = useMemo(
    () =>
      disableSideChatConflict(bindings, sideChatShortcut, openCommaShortcut).bindings,
    [bindings, sideChatShortcut, openCommaShortcut]
  );

  useEffect(() => {
    if (!sideChatShortcut && !openCommaShortcut) return;
    const reconciled = disableSideChatConflict(
      bindings,
      sideChatShortcut,
      openCommaShortcut
    );
    if (!reconciled.changed) return;
    bindingsRef.current = reconciled.bindings;
    void clientSettings.update({
      appShortcutOverrides: appShortcutBindingsToOverrides(
        reconciled.bindings,
        defaults
      ),
    });
  }, [bindings, clientSettings, defaults, sideChatShortcut, openCommaShortcut]);

  const conflictFor = useCallback(
    (id: AppShortcutId, binding: AppKeybinding | null) =>
      findConflict(effectiveBindings, id, binding),
    [effectiveBindings]
  );

  const setBinding = useCallback(
    (id: AppShortcutId, binding: AppKeybinding | null) => {
      const current = disableSideChatConflict(
        bindingsRef.current,
        sideChatShortcut,
        openCommaShortcut
      ).bindings;
      if (
        findConflict(current, id, binding) ||
        (sideChatShortcut &&
          appBindingConflictsWithSideChatShortcut(binding, sideChatShortcut)) ||
        (openCommaShortcut &&
          appBindingConflictsWithSideChatShortcut(binding, openCommaShortcut))
      ) {
        return false;
      }
      const next = { ...current, [id]: binding };
      bindingsRef.current = next;
      void clientSettings.update({
        appShortcutOverrides: appShortcutBindingsToOverrides(next, defaults),
      });
      return true;
    },
    [clientSettings, defaults, sideChatShortcut, openCommaShortcut]
  );

  const resetAll = useCallback(() => {
    const reconciled = disableSideChatConflict(
      defaults,
      sideChatShortcut,
      openCommaShortcut
    );
    bindingsRef.current = reconciled.bindings;
    void clientSettings.update({
      appShortcutOverrides: appShortcutBindingsToOverrides(
        reconciled.bindings,
        defaults
      ),
    });
  }, [clientSettings, defaults, sideChatShortcut, openCommaShortcut]);

  const isDefault = useMemo(
    () =>
      appShortcutIds.every((id) =>
        sameAppKeybinding(effectiveBindings[id], defaults[id])
      ),
    [defaults, effectiveBindings]
  );

  const value = useMemo(
    () => ({
      bindings: effectiveBindings,
      defaultBindings: defaults,
      conflictFor,
      isDefault,
      resetAll,
      setBinding,
    }),
    [conflictFor, defaults, effectiveBindings, isDefault, resetAll, setBinding]
  );

  return (
    <CommaAppShortcutsContext.Provider value={value}>
      {children}
    </CommaAppShortcutsContext.Provider>
  );
}

export function useCommaAppShortcuts() {
  const context = useContext(CommaAppShortcutsContext);
  if (!context) {
    throw new Error(
      "useCommaAppShortcuts must be used within CommaAppShortcutsProvider"
    );
  }
  return context;
}

export function useAppShortcutBinding(id: AppShortcutId): AppKeybinding | null {
  return useCommaAppShortcuts().bindings[id];
}

// For decorative shortcut hints that should degrade gracefully when rendered
// outside the provider (for example in isolated component tests).
export function useOptionalAppShortcutBinding(id: AppShortcutId): AppKeybinding | null {
  return useContext(CommaAppShortcutsContext)?.bindings[id] ?? null;
}
