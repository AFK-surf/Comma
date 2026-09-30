import { createWebAppRuntimeBridge } from "./app-runtime-bridge";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaApp,
  CommaClientSettingsI18nProvider,
  CommaSessionHostProvider,
  CommaWebClientSettingsProvider,
  ProductInboxProjectionProvider,
  createBrowserSessionHostPorts,
  createProductInboxProjectionController,
  createWebSessionHostController,
  defaultApiBaseUrl,
  readWebCommaClientSettings,
  startCommaAnalytics,
  reportCommaClientError,
  CommaAnalyticsLifecycle,
} from "@comma/app";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import { snapshotMatchesSessionProductLease } from "@comma/session-contract";
import "@comma/app/styles.css";

const root = document.getElementById("root");
const initialSettings = readWebCommaClientSettings();
const locale = resolveLocalePreference(initialSettings.localePreference);
initializeCommaI18n([locale]);

if (!root) {
  throw new Error("Root element was not found.");
}

const sessionController = createWebSessionHostController({
  apiBaseUrl: defaultApiBaseUrl(),
  locale,
  ports: createBrowserSessionHostPorts({
    read: (key) => localStorage.getItem(key),
    write: (key, value) => localStorage.setItem(key, value),
  }),
});
const stopAnalytics = startCommaAnalytics({
  runtime: "web",
  lifecycle: sessionController.lifecycle,
});
import.meta.hot?.dispose(stopAnalytics);
const appHost = createWebAppRuntimeBridge(
  new SharedWorker(new URL("./app-runtime.shared-worker.ts", import.meta.url), {
    name: `comma-app-runtime-v1:${defaultApiBaseUrl()}`,
    type: "module",
  }),
  {
    apiBaseUrl: defaultApiBaseUrl(),
    onSessionRejection({ session, status }) {
      if (
        snapshotMatchesSessionProductLease(
          sessionController.lifecycle.getSnapshotSync(),
          session
        )
      )
        sessionController.getProductTransport()?.reportSessionRejection(status);
    },
  }
);
globalThis.commaNative = appHost.bridge;
const productInboxController = createProductInboxProjectionController({
  bridge: appHost.bridge.productInbox,
});
let previousProductLease:
  | import("@comma/session-contract").SessionProductLease
  | undefined;
const stopHostSession = sessionController.lifecycle.subscribe(() => {
  const snapshot = sessionController.lifecycle.getSnapshotSync();
  if (
    previousProductLease &&
    (snapshot.phase === "signed_out" ||
      (snapshot.phase === "signed_in" &&
        snapshot.session.sessionId !== previousProductLease.sessionId))
  )
    appHost.invalidate(previousProductLease);
  if (snapshot.phase === "signed_in")
    previousProductLease = {
      audience: snapshot.session.audience,
      sessionId: snapshot.session.sessionId,
      authorityInstanceId: snapshot.authority.authorityInstanceId,
      generation: snapshot.generation,
    };
  else if (snapshot.phase === "signed_out") previousProductLease = undefined;
});
import.meta.hot?.dispose(() => {
  stopHostSession();
  appHost.disconnect();
});
window.addEventListener("pagehide", (event) => {
  if (!event.persisted) appHost.disconnect();
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
          <ProductInboxProjectionProvider controller={productInboxController}>
            <CommaAnalyticsLifecycle>
              <CommaApp />
            </CommaAnalyticsLifecycle>
          </ProductInboxProjectionProvider>
        </CommaSessionHostProvider>
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  </StrictMode>
);
