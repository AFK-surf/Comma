import { installMiniAppHost, type MiniAppNativeBridge } from "./native-host.ts";

/** Installed only in the main frame's isolated WKContentWorld. App code never receives this bridge. */
export function install() {
  const native = (
    globalThis as unknown as {
      webkit: { messageHandlers: { miniApp: MiniAppNativeBridge } };
    }
  ).webkit.messageHandlers.miniApp;
  return installMiniAppHost(native);
}
