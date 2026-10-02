import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui";
import { getNativeBridge } from "@comma/native-bridge";
import { useSyncExternalStore } from "react";
import { openNativePlatformExternalUrl } from "../runtime-chat/nativePlatformActions";

/**
 * The website's download page. `start=mac` makes the page begin the macOS
 * download as it opens (website/src/main.ts).
 */
export const commaMacDownloadUrl = "https://comma.surf/download?start=mac";

export type DesktopAppFeature =
  | "browser"
  | "computer-use"
  | "compute-node"
  | "device-connect"
  | "dock"
  | "keep-awake"
  | "launch-at-login"
  | "meeting"
  | "menu-bar"
  | "notifications"
  | "voice";

/** A browser has none of the desktop app's native capabilities. */
export function needsDesktopApp() {
  return getNativeBridge().platform !== "electron";
}

// The feature outlives the open flag so the closing dialog keeps its text.
let prompt: { feature: DesktopAppFeature; open: boolean } | undefined;
const listeners = new Set<() => void>();

function publish(next: typeof prompt) {
  prompt = next;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

const read = () => prompt;

/**
 * Tells a web user that a feature they tried needs the Comma app for Mac.
 * One dialog per window; a second request replaces the first. The desktop
 * app never shows it, whichever caller asks.
 */
export function requestDesktopApp(feature: DesktopAppFeature) {
  if (!needsDesktopApp()) return;
  publish({ feature, open: true });
}

type Messages = ReturnType<typeof useCommaMessages>;

const featureLabels: Record<DesktopAppFeature, (m: Messages) => string> = {
  browser: (m) => m.desktop_app_feature_browser(),
  "computer-use": (m) => m.desktop_app_feature_computer_use(),
  "compute-node": (m) => m.desktop_app_feature_compute_node(),
  "device-connect": (m) => m.desktop_app_feature_device_connect(),
  dock: (m) => m.desktop_app_feature_dock(),
  "keep-awake": (m) => m.desktop_app_feature_keep_awake(),
  "launch-at-login": (m) => m.desktop_app_feature_launch_at_login(),
  meeting: (m) => m.desktop_app_feature_meeting(),
  "menu-bar": (m) => m.desktop_app_feature_menu_bar(),
  notifications: (m) => m.desktop_app_feature_notifications(),
  voice: (m) => m.desktop_app_feature_voice(),
};

export function DesktopAppPromptHost() {
  const m = useCommaMessages();
  const current = useSyncExternalStore(subscribe, read, read);
  if (!current) return null;
  const close = () => publish({ ...current, open: false });

  return (
    <Dialog
      isOpen={current.open}
      onOpenChange={(open) => {
        if (!open) close();
      }}
      title={m.desktop_app_required_title()}
      description={m.desktop_app_required_description({
        feature: featureLabels[current.feature](m),
      })}
      actions={[
        { label: m.desktop_app_required_cancel(), hierarchy: "secondary-gray" },
        {
          label: m.desktop_app_required_download(),
          hierarchy: "primary",
          onPress: () => {
            close();
            void openNativePlatformExternalUrl(commaMacDownloadUrl);
          },
        },
      ]}
    />
  );
}
