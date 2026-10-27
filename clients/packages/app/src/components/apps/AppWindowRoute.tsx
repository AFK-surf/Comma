import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { useHasTrafficLights, WindowButtons } from "../WindowBar";
import { MiniAppFrame } from "./MiniAppFrame";

/**
 * An app as the whole of its own window (Mac "Open in window"): only the app, without Comma's rail, window bar or
 * content panel. The app's own bar is the window's title bar: the window is dragged by it, macOS paints the traffic
 * lights into its start and Windows draws its buttons at its end. It stays inside the signed-in session, so the app's
 * calls reach the core as they do in the right panel.
 */
export function AppWindowRoute({
  workspaceId,
  appId,
  version,
}: {
  workspaceId: string;
  appId: string;
  version?: number | undefined;
}) {
  const messages = useCommaMessages();
  const bridge = getNativeBridge();
  const hasWindowButtons = bridge.platform === "electron" && bridge.os === "windows";
  const hasTrafficLights = useHasTrafficLights();
  return (
    <main
      className="flex h-screen min-h-0 w-full min-w-0 flex-col bg-primary text-primary"
      data-os={bridge.os}
      data-platform={bridge.platform}
      data-testid="app-window-route"
    >
      <MiniAppFrame
        appId={appId}
        detail={
          version === undefined
            ? undefined
            : messages.mini_app_preview_version({ version: String(version) })
        }
        headerClassName="comma-window-titlebar-region"
        leading={
          // macOS paints the traffic lights at 12-64px from the window's edge, centred on the bar (window-options.ts).
          // The bar's 20px start padding and this 52px slot end past them, so the name starts after the lights.
          hasTrafficLights ? (
            <div
              aria-hidden="true"
              className="h-8 w-13 shrink-0"
              data-testid="app-window-traffic-lights"
            />
          ) : null
        }
        trailing={hasWindowButtons ? <WindowButtons /> : null}
        variant="flush"
        version={version}
        via={{ workspace: workspaceId }}
      />
    </main>
  );
}
