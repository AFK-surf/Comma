import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaApp,
  CommaAppearanceProvider,
  MeetingRecorderWindowApp,
  SitePermissionMenuApp,
  BrowserInspectionComposer,
  CommaClientSettingsI18nProvider,
  CommaElectronClientSettingsProvider,
  CommaReducedMotionRootSync,
  CommaSessionHostProvider,
  ProductInboxProjectionProvider,
  SideChatApp,
  SideChatTestWindow,
  createElectronProductInboxProjectionController,
  createElectronSessionHostController,
  readLegacyCommaClientSettings,
  setToastsEnabled,
  startCommaAnalytics,
  reportCommaClientError,
  CommaAnalyticsLifecycle,
} from "@comma/app";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import { defaultCommaClientSettings, getNativeBridge } from "@comma/native-bridge";
import "@comma/app/styles.css";

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
const isSideChatWindow = rendererRole === "side-chat-window";
const isSideChatTestWindow = rendererRole === "side-chat-test-window";
if (isSideChatWindow || isSideChatTestWindow) {
  // Set before React's first paint so the transparent window never flashes the
  // main-app background while the Side Chat effect tree is mounting.
  const commaWindowRole = isSideChatWindow ? "side-chat" : "side-chat-test";
  document.documentElement.dataset.commaWindowRole = commaWindowRole;
  document.body.dataset.commaWindowRole = commaWindowRole;
}
const RendererApp = isBrowserInspectionComposer
  ? BrowserInspectionComposer
  : isSideChatTestWindow
    ? SideChatTestWindow
    : isSideChatWindow
      ? SideChatApp
      : CommaApp;
// Only CommaApp mounts a <Toaster />, so only CommaApp has a toast surface. Say so
// explicitly rather than leaving it to whether a stack happens to be mounted:
// sonner's store is module-global and its dismiss timers live in <Toaster />, so
// a toast raised from a shared chat component here would be retained forever in
// these long-lived accessory windows.
setToastsEnabled(
  !isSitePermissionMenu &&
    !isMeetingRecorderWindow &&
    !isBrowserInspectionComposer &&
    !isSideChatWindow &&
    !isSideChatTestWindow
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
                <MeetingRecorderWindowApp />
              )}
            </CommaReducedMotionRootSync>
          </CommaClientSettingsI18nProvider>
        </CommaElectronClientSettingsProvider>
      </StrictMode>
    );
    return;
  }
  const sessionController = createElectronSessionHostController({ locale });
  if (rendererRole === "main-window" || rendererRole === "side-chat-window") {
    const stopAnalytics = startCommaAnalytics({
      runtime: "electron",
      windowRole: rendererRole,
      lifecycle: sessionController.lifecycle,
    });
    import.meta.hot?.dispose(stopAnalytics);
  }
  const productInboxController = createElectronProductInboxProjectionController();
  const rendererApp = <RendererApp />;
  const reducedMotionAwareRenderer = isSideChatTestWindow ? (
    <CommaReducedMotionRootSync>{rendererApp}</CommaReducedMotionRootSync>
  ) : (
    rendererApp
  );

  createRoot(root!, {
    onUncaughtError: (error) => {
      console.error(error);
      reportCommaClientError(error, "react_uncaught");
    },
  }).render(
    <StrictMode>
      <CommaElectronClientSettingsProvider
        initialPreferences={initialPreferences}
        migrationSettings={migrationSettings}
      >
        <CommaClientSettingsI18nProvider>
          <CommaSessionHostProvider controller={sessionController}>
            <ProductInboxProjectionProvider controller={productInboxController}>
              <CommaAnalyticsLifecycle>
                {reducedMotionAwareRenderer}
              </CommaAnalyticsLifecycle>
            </ProductInboxProjectionProvider>
          </CommaSessionHostProvider>
        </CommaClientSettingsI18nProvider>
      </CommaElectronClientSettingsProvider>
    </StrictMode>
  );
}

void renderComma();
