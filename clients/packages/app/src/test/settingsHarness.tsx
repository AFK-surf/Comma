import { useState, type ReactNode } from "react";
import {
  createSettingsRegistry,
  SettingsDialog,
  type SettingsCategoryDefinition,
} from "@comma/ui/components/settings";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { AppSettingsRoute } from "../components/AppSettingsRoute";
import {
  CommaAuthContext,
  type CommaAuthContextValue,
} from "../components/auth-context";
import { CommaAppearanceProvider } from "../components/commaAppearance";
import {
  CommaClientSettingsI18nProvider,
  CommaWebClientSettingsProvider,
} from "../components/commaClientSettings";
import { RouterIdentityProvider } from "../components/router-identity/RouterIdentityProvider";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";

/** A signed-in web session (Settings reads through the core, not this API). */
export function settingsAuth(): CommaAuthContextValue {
  const session = new AbortController();
  const sessionTransport = {
    applyHeaders: () => undefined,
    credentials: "include" as const,
    reportSessionRejection: () => undefined,
    signal: session.signal,
  };
  return {
    apiBaseUrl: "https://api.example",
    authenticated: true,
    productLease: {
      audience: "https://api.example",
      authorityInstanceId: "test-authority",
      generation: 1,
      sessionId: "session-1",
    },
    sessionSignal: session.signal,
    sessionTransport,
    signOut: () => undefined,
    userDisplayName: "Ada",
    userEmail: "ada@example.com",
  };
}

/** Settings as the web client mounts it, over `core` (by default a scripted core that answers nothing). */
export function WebSettings({
  auth = settingsAuth(),
  core: given,
}: {
  auth?: CommaAuthContextValue;
  core?: { wrap: (ui: ReactNode) => ReactNode };
}) {
  const [core] = useState<{ wrap: (ui: ReactNode) => ReactNode }>(
    () => given ?? createScriptedCore()
  );
  return core.wrap(
    <CommaWebClientSettingsProvider>
      <CommaClientSettingsI18nProvider>
        <CommaAuthContext.Provider value={auth}>
          <RouterIdentityProvider>
            <CommaAppearanceProvider>
              <CommaAppShortcutsProvider>
                <AppSettingsRoute />
              </CommaAppShortcutsProvider>
            </CommaAppearanceProvider>
          </RouterIdentityProvider>
        </CommaAuthContext.Provider>
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  );
}

/**
 * One category alone in the Settings dialog. A test of a category renders only
 * it: its queries then search that category's rows, not every category's, and
 * a change re-renders it, not all of Settings.
 */
export function SettingsCategory({
  category,
}: {
  category: SettingsCategoryDefinition;
}) {
  return (
    <SettingsDialog
      activeCategoryId={category.id}
      ariaLabel="Settings sections"
      closeLabel="Close settings"
      contentAriaLabel="Settings content"
      onClose={() => undefined}
      registry={createSettingsRegistry({
        groups: [{ id: "category", categories: [category] }],
      })}
      searchAriaLabel="Search settings"
      searchPlaceholder="Search"
    />
  );
}

export const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
