import { SitePermissionMenuApp } from "../../../../../packages/app/src/components/SitePermissionMenuApp";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { CommaI18nProvider } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { RightSidebarBrowserToolbar } from "@comma/ui/components/right-sidebar";
import { Toaster } from "@comma/ui/components/toast";
import { toast as sonnerToast } from "sonner";
import { MeetingRecorderHost } from "../../../../../packages/app/src/components/MeetingRecorderHost";
import { MeetingRecorderWindowApp } from "../../../../../packages/app/src/components/MeetingRecorderWindowApp";
import { CoreClient, CoreProvider, electronCoreOpener } from "@comma/core-client";
import "@comma/app/styles.css";
// Test-only observations: retain bounded projection history without changing the host.
const recorderStates: unknown[] = [];
const permissionsWindow = getNativeBridge().self.role === "site-permission-menu";
// Every recorder surface shows the client core's meeting recorder (the menu window has no core channel).
const core = permissionsWindow
  ? null
  : new CoreClient(electronCoreOpener(() => getNativeBridge().core.open()));
core?.subscribe(
  { topic: "meetingRecorder" },
  (state) => {
    recorderStates.push(state);
    if (recorderStates.length > 30) recorderStates.shift();
  },
  () => undefined
);
Object.assign(window, {
  recorderDiagnostics: () => ({
    states: recorderStates,
    toastIds: sonnerToast.getToasts().map((toast) => toast.id),
    documentVisibility: document.visibilityState,
    focused: document.hasFocus(),
  }),
});
const permissionsMenu = getNativeBridge().self.role === "site-permission-menu";
if (permissionsMenu) {
  document.documentElement.dataset.commaWindowRole = "site-permission-menu";
  document.body.dataset.commaWindowRole = "site-permission-menu";
}
const desktop = getNativeBridge().self.role === "meeting-recorder-window";
if (desktop) {
  document.documentElement.dataset.commaWindowRole = "meeting-recorder";
  document.body.dataset.commaWindowRole = "meeting-recorder";
}
function ClientRecorder() {
  const [area, setArea] = useState<HTMLDivElement | null>(null);
  return (
    <>
      <div
        ref={setArea}
        data-testid="recorder-content-area"
        style={{ width: "60vw", height: "100vh" }}
      />
      <div style={{ position: "fixed", top: 0, left: 0, width: "100vw" }}>
        <RightSidebarBrowserToolbar
          address="https://meet.google.com/"
          canGoBack={false}
          canGoForward={false}
          onAddressChange={() => {}}
          onAddressSubmit={() => {}}
          onBack={() => {}}
          onForward={() => {}}
          onReload={() => {}}
          onPageMenu={(anchor) => {
            void getNativeBridge().browserSidebar.showPermissions({
              sessionId: "meet",
              anchor,
            });
          }}
        />
      </div>
      <MeetingRecorderHost containment={area} />
      <Toaster />
    </>
  );
}
createRoot(document.getElementById("root")!).render(
  <CommaI18nProvider locale="en">
    {permissionsMenu || !core ? (
      <SitePermissionMenuApp />
    ) : (
      <CoreProvider client={core}>
        {desktop ? <MeetingRecorderWindowApp /> : <ClientRecorder />}
      </CoreProvider>
    )}
  </CommaI18nProvider>
);
