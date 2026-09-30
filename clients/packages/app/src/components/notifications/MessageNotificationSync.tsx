import { getNativeBridge } from "@comma/native-bridge";
import { useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";

/**
 * Bridges a click on a Main-raised message notification back into the product
 * window, so it lands on the Router chat. Main owns the banner, its sound and
 * the app icon badge, so System Settings governs all three.
 */
export function MessageNotificationSync() {
  const bridge = getNativeBridge();
  const isDesktop = bridge.platform === "electron";
  const navigate = useNavigate();

  useEffect(() => {
    if (!isDesktop) return;

    return bridge.messageNotifications.onEvent(() => {
      void navigate({ to: "/" });
    });
  }, [bridge, isDesktop, navigate]);

  return null;
}
