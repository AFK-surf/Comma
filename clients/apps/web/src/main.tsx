import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaApp,
  CommaClientSettingsI18nProvider,
  CommaSessionHostProvider,
  CommaWebClientSettingsProvider,
  createCoreSessionHostController,
  defaultApiBaseUrl,
  readWebCommaClientSettings,
  startCommaAnalytics,
  reportCommaClientError,
  CommaAnalyticsLifecycle,
} from "@comma/app";
import { CoreProvider } from "@comma/core-client";
import { connectWebCore } from "./connect-core";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import { webNativeBridge } from "@comma/native-bridge";
import "@comma/app/styles.css";

const root = document.getElementById("root");
const initialSettings = readWebCommaClientSettings();
const locale = resolveLocalePreference(initialSettings.localePreference);
initializeCommaI18n([locale]);

if (!root) {
  throw new Error("Root element was not found.");
}

// Each tab is a window of its own: its chat leases and presentation are its own in the shared core.
const windowId = `web:${crypto.randomUUID()}`;
globalThis.commaNative = {
  ...webNativeBridge,
  self: { role: "main-window", windowId },
};

const apiBaseUrl = defaultApiBaseUrl();
const { core, dispose: disposeCore } = connectWebCore(apiBaseUrl, {
  onFault: (error) => reportCommaClientError(error, "core_fault"),
});
// The tab's channel to the core: what E2E drives.
(globalThis as { commaCore?: typeof core }).commaCore = core;
// The session is the core's: the page shows it and asks the core to change it.
const sessionController = createCoreSessionHostController({ apiBaseUrl, core, locale });
const stopAnalytics = startCommaAnalytics({
  runtime: "web",
  lifecycle: sessionController.lifecycle,
});
import.meta.hot?.dispose(stopAnalytics);
import.meta.hot?.dispose(() => {
  sessionController.dispose?.();
  disposeCore();
});
createRoot(root, {
  onUncaughtError: (error) => {
    console.error(error);
    reportCommaClientError(error, "react_uncaught");
  },
}).render(
  <StrictMode>
    <CommaWebClientSettingsProvider initialSettings={initialSettings}>
      <CommaClientSettingsI18nProvider>
        <CommaSessionHostProvider controller={sessionController}>
          <CoreProvider client={core}>
            <CommaAnalyticsLifecycle>
              <CommaApp />
            </CommaAnalyticsLifecycle>
          </CoreProvider>
        </CommaSessionHostProvider>
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  </StrictMode>
);
