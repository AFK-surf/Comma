import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaClientSettingsI18nProvider,
  CommaWebClientSettingsProvider,
  PublicTaskShareApp,
  createPublicShareClient,
  defaultApiBaseUrl,
  readWebCommaClientSettings,
  shareTokenFromPath,
} from "@comma/app/task-share";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import "@comma/app/styles.css";

// A public share page holds no Comma session. The link token is its only authority.
const root = document.getElementById("root");
if (!root) throw new Error("Root element was not found.");

const initialSettings = readWebCommaClientSettings();
initializeCommaI18n([resolveLocalePreference(initialSettings.localePreference)]);
const token = shareTokenFromPath(location.pathname) ?? "";
const client = createPublicShareClient(defaultApiBaseUrl(), token);

createRoot(root).render(
  <StrictMode>
    <CommaWebClientSettingsProvider initialSettings={initialSettings}>
      <CommaClientSettingsI18nProvider>
        <PublicTaskShareApp client={client} />
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  </StrictMode>
);
