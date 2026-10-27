import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaApp,
  CommaAppearanceProvider,
  MeetingRecorderWindowApp,
  OnboardingWindowApp,
  SitePermissionMenuApp,
  BrowserInspectionComposer,
  CommaClientSettingsI18nProvider,
  CommaElectronClientSettingsProvider,
  CommaReducedMotionRootSync,
  CommaSessionHostProvider,
  createCoreSessionHostController,
  readLegacyCommaClientSettings,
  setToastsEnabled,
  startCommaAnalytics,
  reportCommaClientError,
  CommaAnalyticsLifecycle,
} from "@comma/app";
import { CoreClient, CoreProvider, electronCoreOpener } from "@comma/core-client";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import { defaultCommaClientSettings, getNativeBridge } from "@comma/native-bridge";
import "@comma/app/styles.css";
import { dismissMainWindowBoot } from "./mainWindowBoot";
import { MainWindowBootDismissal } from "./MainWindowBootDismissal";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Root element was not found.");
}

const rendererRole = getNativeBridge().self.role;
const isBrowserInspectionComposer = location.hash.startsWith(
  "#/browser-inspection-composer"
);
if (isBrowserInspectionComposer) {
  document.documentElement.dataset.commaWindowRole = "browser-inspection-composer";
  document.body.dataset.commaWindowRole = "browser-inspection-composer";
}
const isSitePermissionMenu = rendererRole === "site-permission-menu";
if (isSitePermissionMenu) {
  document.documentElement.dataset.commaWindowRole = "site-permission-menu";
  document.body.dataset.commaWindowRole = "site-permission-menu";
}
const isMeetingRecorderWindow = rendererRole === "meeting-recorder-window";
if (isMeetingRecorderWindow) {
  document.documentElement.dataset.commaWindowRole = "meeting-recorder";
  document.body.dataset.commaWindowRole = "meeting-recorder";
}
const isOnboardingWindow = rendererRole === "onboarding-window";
if (isOnboardingWindow) {
  // The onboarding window covers the whole display: its page stays transparent
  // from the first paint, and the experience draws the veil over the desktop.
  document.documentElement.dataset.commaWindowRole = "onboarding";
  document.body.dataset.commaWindowRole = "onboarding";
}
const windowMaterial = getNativeBridge().windowMaterial;
if (rendererRole === "main-window" && windowMaterial) {
  // Main drew this window over a system material (window-options.ts): the
  // page leaves its root clear and the shell tints it.
  document.documentElement.dataset.commaWindowMaterial = windowMaterial;
}
const RendererApp = isBrowserInspectionComposer
  ? BrowserInspectionComposer
  : isOnboardingWindow
    ? OnboardingWindowApp
    : CommaApp;
// Only CommaApp and OnboardingWindowApp mount a <Toaster />, so only they have a
// toast surface; the onboarding window needs one for plugin authorization
// failures. Say so explicitly rather than leaving it to whether a stack happens
// to be mounted: sonner's store is module-global and its dismiss timers live in
// <Toaster />, so a toast raised from a shared chat component here would be
// retained forever in these long-lived accessory windows.
setToastsEnabled(
  !isSitePermissionMenu && !isMeetingRecorderWindow && !isBrowserInspectionComposer
);

async function renderComma() {
  const bridge = getNativeBridge();
  const initialPreferences = await bridge.appPreferences.state
    .get()
    .catch(() => undefined);
  const migrationSettings =
    rendererRole === "main-window" && !initialPreferences?.clientSettings
      ? readLegacyCommaClientSettings()
      : undefined;
  const initialClientSettings =
    initialPreferences?.clientSettings ??
    migrationSettings ??
    defaultCommaClientSettings;
  const locale = resolveLocalePreference(initialClientSettings.localePreference);
  initializeCommaI18n([locale]);
  if (isMeetingRecorderWindow || isSitePermissionMenu) {
    createRoot(root!).render(
      <StrictMode>
        <CommaElectronClientSettingsProvider initialPreferences={initialPreferences}>
          <CommaClientSettingsI18nProvider>
            <CommaReducedMotionRootSync>
              {isSitePermissionMenu ? (
                <CommaAppearanceProvider syncNativeAppearance={false}>
                  <SitePermissionMenuApp />
                </CommaAppearanceProvider>
              ) : (
                // The recorder shows the client core's meeting recorder: a channel of its own, no session calls.
                <CoreProvider
                  client={
                    new CoreClient(
                      electronCoreOpener(() => bridge.core.open()),
                      {
                        onFault: (error) => reportCommaClientError(error, "core_fault"),
                      }
                    )
                  }
                >
                  <MeetingRecorderWindowApp />
                </CoreProvider>
              )}
            </CommaReducedMotionRootSync>
          </CommaClientSettingsI18nProvider>
        </CommaElectronClientSettingsProvider>
      </StrictMode>
    );
    return;
  }
  // The client core, in its utility process: Main hands this window a channel. It runs the session; Main keeps the
  // bearer and adds it to this window's product requests (its `/v1` proxy).
  const core = new CoreClient(
    electronCoreOpener(() => bridge.core.open()),
    { onFault: (error) => reportCommaClientError(error, "core_fault") }
  );
  // The window's channel to the core: what E2E drives.
  (globalThis as { commaCore?: CoreClient }).commaCore = core;
  const sessionController = createCoreSessionHostController({
    apiBaseUrl: "assets://.",
    core,
    host: "electron",
    locale,
  });
  if (rendererRole === "main-window") {
    const stopAnalytics = startCommaAnalytics({
      runtime: "electron",
      lifecycle: sessionController.lifecycle,
      desktopLaunch: bridge.native
        .info()
        .then((info) => info.desktopLaunch)
        .catch(() => undefined),
    });
    import.meta.hot?.dispose(stopAnalytics);
  }
  createRoot(root!, {
    onUncaughtError: (error) => {
      console.error(error);
      reportCommaClientError(error, "react_uncaught");
      dismissMainWindowBoot();
    },
  }).render(
    <StrictMode>
      <CommaElectronClientSettingsProvider
        initialPreferences={initialPreferences}
        migrationSettings={migrationSettings}
      >
        <CommaClientSettingsI18nProvider>
          <CommaSessionHostProvider controller={sessionController}>
            {rendererRole === "main-window" ? <MainWindowBootDismissal /> : null}
            <CoreProvider client={core}>
              <CommaAnalyticsLifecycle>
                <RendererApp />
              </CommaAnalyticsLifecycle>
            </CoreProvider>
          </CommaSessionHostProvider>
        </CommaClientSettingsI18nProvider>
      </CommaElectronClientSettingsProvider>
    </StrictMode>
  );
}

void renderComma();
