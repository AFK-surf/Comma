import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CollabGuestApp,
  CommaAppearanceProvider,
  CommaClientSettingsI18nProvider,
  CommaWebClientSettingsProvider,
  collabTokenFromPath,
  createCollabGuestClient,
  defaultApiBaseUrl,
  readWebCommaClientSettings,
} from "@comma/app/collab-guest";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import "@comma/app/styles.css";

// A guest collaboration page holds no Comma account session. The invite token
// and its verified guest session token are its only authority.
const root = document.getElementById("root");
if (!root) throw new Error("Root element was not found.");

const initialSettings = readWebCommaClientSettings();
initializeCommaI18n([resolveLocalePreference(initialSettings.localePreference)]);
const inviteToken = collabTokenFromPath(location.pathname) ?? "";
const client = createCollabGuestClient(defaultApiBaseUrl(), inviteToken);

createRoot(root).render(
  <StrictMode>
    <CommaWebClientSettingsProvider initialSettings={initialSettings}>
      <CommaClientSettingsI18nProvider>
        {/* A guest's light or dark follows their system, as the app's does by default; no native window to sync. */}
        <CommaAppearanceProvider syncNativeAppearance={false}>
          <CollabGuestApp client={client} inviteToken={inviteToken} />
        </CommaAppearanceProvider>
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  </StrictMode>
);
