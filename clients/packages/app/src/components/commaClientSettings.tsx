import {
  commaClientSettingsPatchSchema,
  commaClientSettingsSchema,
  defaultCommaClientSettings,
  getNativeBridge,
  type AppPreferences,
  type CommaClientSettings,
  type CommaClientSettingsPatch,
} from "@comma/native-bridge";
import { CommaI18nProvider } from "@comma/i18n/react";
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
import { readLegacyCommaClientSettings } from "./readLegacyCommaClientSettings";

export const commaClientSettingsStorageKey = "comma.client-settings";

interface CommaClientSettingsContextValue {
  settings: CommaClientSettings;
  update(
    patch: CommaClientSettingsPatch,
    options?: { throwOnError: boolean }
  ): Promise<void>;
}

const CommaClientSettingsContext =
  createContext<CommaClientSettingsContextValue | null>(null);

const CommaClientSettingsPendingContext = createContext<boolean>(false);

const mergeClientSettings = (
  current: CommaClientSettings,
  patch: CommaClientSettingsPatch
) =>
  commaClientSettingsSchema.parse({
    ...current,
    ...patch,
    appearance: patch.appearance
      ? { ...current.appearance, ...patch.appearance }
      : current.appearance,
  });

/** Main compares its own copies the same way; both are schema-ordered JSON. */
const sameClientSettings = (left: CommaClientSettings, right: CommaClientSettings) =>
  left === right || JSON.stringify(left) === JSON.stringify(right);

export function readWebCommaClientSettings(): CommaClientSettings {
  try {
    const stored = globalThis.localStorage?.getItem(commaClientSettingsStorageKey);
    if (stored) {
      const parsed = commaClientSettingsSchema.safeParse(JSON.parse(stored));
      if (parsed.success) return parsed.data;
    }
  } catch {
    // Fall through to the read-only legacy migration snapshot.
  }
  return readLegacyCommaClientSettings();
}

function storeWebCommaClientSettings(settings: CommaClientSettings) {
  try {
    globalThis.localStorage?.setItem(
      commaClientSettingsStorageKey,
      JSON.stringify(commaClientSettingsSchema.parse(settings))
    );
  } catch {
    // Browser storage is best effort; the current tab keeps its in-memory state.
  }
}

export function CommaWebClientSettingsProvider({
  children,
  initialSettings,
}: {
  children: ReactNode;
  initialSettings?: CommaClientSettings | undefined;
}) {
  const [settings, setSettings] = useState<CommaClientSettings>(() =>
    commaClientSettingsSchema.parse(initialSettings ?? readWebCommaClientSettings())
  );

  useEffect(() => storeWebCommaClientSettings(settings), [settings]);

  useEffect(() => {
    const acceptStoredSettings = (event: StorageEvent) => {
      if (event.key !== commaClientSettingsStorageKey && event.key !== null) return;
      setSettings(readWebCommaClientSettings());
    };
    window.addEventListener("storage", acceptStoredSettings);
    return () => window.removeEventListener("storage", acceptStoredSettings);
  }, []);

  const update = useCallback(async (patch: CommaClientSettingsPatch) => {
    const parsedPatch = commaClientSettingsPatchSchema.parse(patch);
    setSettings((current) => mergeClientSettings(current, parsedPatch));
  }, []);

  const value = useMemo(() => ({ settings, update }), [settings, update]);

  return (
    <CommaClientSettingsContext.Provider value={value}>
      <CommaClientSettingsPendingContext.Provider value={false}>
        {children}
      </CommaClientSettingsPendingContext.Provider>
    </CommaClientSettingsContext.Provider>
  );
}

export function CommaElectronClientSettingsProvider({
  children,
  initialPreferences,
  migrationSettings,
}: {
  children: ReactNode;
  initialPreferences?: AppPreferences | undefined;
  migrationSettings?: CommaClientSettings | undefined;
}) {
  const bridge = getNativeBridge();
  const parsedMigrationSettings = useMemo(
    () =>
      migrationSettings
        ? commaClientSettingsSchema.parse(migrationSettings)
        : undefined,
    [migrationSettings]
  );
  const initialSettings =
    initialPreferences?.clientSettings ??
    parsedMigrationSettings ??
    structuredClone(defaultCommaClientSettings);
  const [settings, setSettings] = useState<CommaClientSettings>(initialSettings);
  const [pendingCount, setPendingCount] = useState(0);
  const highWaterRevisionRef = useRef(initialPreferences?.revision ?? 0);
  const ownerHasSettingsRef = useRef(initialPreferences?.clientSettings !== undefined);
  const migrationStartedRef = useRef(false);

  // Modeled in tla/app-preferences/AppPreferences.tla: command ACKs, replay,
  // and live events may reorder, so a renderer accepts only monotonic owner
  // snapshots. Only Main publishes this state.
  const acceptPreferences = useCallback((snapshot: AppPreferences) => {
    if (snapshot.revision < highWaterRevisionRef.current) return;
    highWaterRevisionRef.current = snapshot.revision;
    const next = snapshot.clientSettings;
    if (!next) return;
    ownerHasSettingsRef.current = true;
    // Every preference change, such as the Notch switch, arrives as a whole new
    // snapshot. Unchanged settings keep their identity, so the chat, sidebar
    // and appearance consumers in every window do not render for it.
    setSettings((current) => (sameClientSettings(current, next) ? current : next));
  }, []);

  useEffect(
    () => bridge.appPreferences.state.subscribe(acceptPreferences),
    [acceptPreferences, bridge]
  );

  useEffect(() => {
    if (
      !parsedMigrationSettings ||
      ownerHasSettingsRef.current ||
      migrationStartedRef.current
    ) {
      return;
    }
    migrationStartedRef.current = true;
    setPendingCount((count) => count + 1);
    void bridge.appPreferences
      .initializeClientSettings(parsedMigrationSettings)
      .then(acceptPreferences)
      .catch(() => bridge.appPreferences.state.get().then(acceptPreferences))
      .catch(() => undefined)
      .finally(() => setPendingCount((count) => Math.max(0, count - 1)));
  }, [acceptPreferences, bridge, parsedMigrationSettings]);

  const update = useCallback(
    async (patch: CommaClientSettingsPatch, options?: { throwOnError: boolean }) => {
      const parsedPatch = commaClientSettingsPatchSchema.parse(patch);
      setPendingCount((count) => count + 1);
      try {
        acceptPreferences(
          await bridge.appPreferences.update({ clientSettings: parsedPatch })
        );
      } catch (error) {
        try {
          acceptPreferences(await bridge.appPreferences.state.get());
        } catch {
          // Keep the last owner snapshot if native recovery is also unavailable.
        }
        if (options?.throwOnError) throw error;
      } finally {
        setPendingCount((count) => Math.max(0, count - 1));
      }
    },
    [acceptPreferences, bridge]
  );

  const value = useMemo(() => ({ settings, update }), [settings, update]);

  const pending = pendingCount > 0;

  return (
    <CommaClientSettingsContext.Provider value={value}>
      <CommaClientSettingsPendingContext.Provider value={pending}>
        {children}
      </CommaClientSettingsPendingContext.Provider>
    </CommaClientSettingsContext.Provider>
  );
}

export function CommaClientSettingsI18nProvider({ children }: { children: ReactNode }) {
  const { settings, update } = useCommaClientSettings();
  return (
    <CommaI18nProvider
      localePreference={settings.localePreference}
      onLocalePreferenceChange={(localePreference) => update({ localePreference })}
    >
      {children}
    </CommaI18nProvider>
  );
}

export function useCommaClientSettings() {
  const value = useContext(CommaClientSettingsContext);
  if (!value) {
    throw new Error(
      "useCommaClientSettings must be used within a Comma client-settings owner."
    );
  }
  return value;
}

export function useCommaClientSettingsPending() {
  return useContext(CommaClientSettingsPendingContext);
}
