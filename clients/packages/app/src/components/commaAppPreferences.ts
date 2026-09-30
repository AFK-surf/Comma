import {
  getNativeBridge,
  type AppPreferences,
  type AppPreferencesPatch,
} from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";

export function useCommaAppPreferences() {
  const bridge = getNativeBridge();
  const available = bridge.platform === "electron";
  const availability = {
    launchAtLogin: available && (bridge.os === "macos" || bridge.os === "windows"),
    notifications: available,
    showInAirDrop: available && bridge.os === "macos",
    showInDock: available && bridge.os === "macos",
    showInMenuBar: available,
    showInNotch: available && bridge.os === "macos",
  };
  const showInSystemTray = available && bridge.os !== "macos";
  const [preferences, setPreferences] = useState<AppPreferences | null>(null);
  const [pending, setPending] = useState(false);
  const operationRef = useRef(0);
  const updatePendingRef = useRef(false);
  // Modeled in tla/app-preferences/AppPreferences.tla: acknowledgements,
  // replays, and events may arrive out of order, so only monotonic snapshots win.
  const acceptPreferences = useCallback((snapshot: AppPreferences) => {
    setPreferences((current) =>
      current && current.revision > snapshot.revision ? current : snapshot
    );
  }, []);

  useEffect(() => {
    if (!available) return;
    return bridge.appPreferences.state.subscribe(acceptPreferences);
  }, [acceptPreferences, available, bridge]);

  // Login-item and OS notification truth are owned outside Comma and change
  // behind its back, so a window coming back into view re-reads them.
  useEffect(() => {
    if (!available || pending) return;

    const refreshNativeReadbacks = () => {
      if (updatePendingRef.current) return;
      const operation = operationRef.current;
      void bridge.appPreferences.state
        .get()
        .then((snapshot) => {
          if (operationRef.current === operation) acceptPreferences(snapshot);
        })
        .catch(() => {
          // Keep the last acknowledged snapshot when native state is unavailable.
        });
    };
    const refreshNativeReadbacksWhenVisible = () => {
      if (document.visibilityState === "visible") refreshNativeReadbacks();
    };

    window.addEventListener("focus", refreshNativeReadbacks);
    document.addEventListener("visibilitychange", refreshNativeReadbacksWhenVisible);
    return () => {
      window.removeEventListener("focus", refreshNativeReadbacks);
      document.removeEventListener(
        "visibilitychange",
        refreshNativeReadbacksWhenVisible
      );
    };
  }, [acceptPreferences, available, bridge, pending]);

  const update = useCallback(
    async (patch: AppPreferencesPatch) => {
      if (!available) return;
      const operation = ++operationRef.current;
      updatePendingRef.current = true;
      setPending(true);
      try {
        const acknowledged = await bridge.appPreferences.update(patch);
        if (operationRef.current === operation) acceptPreferences(acknowledged);
      } catch {
        if (operationRef.current === operation) {
          try {
            acceptPreferences(await bridge.appPreferences.state.get());
          } catch {
            // Keep the last acknowledged snapshot when native recovery also fails.
          }
        }
      } finally {
        if (operationRef.current === operation) {
          updatePendingRef.current = false;
          setPending(false);
        }
      }
    },
    [acceptPreferences, available, bridge]
  );

  const openNotificationSettings = useCallback(async () => {
    if (!available) return { opened: false as const };
    return bridge.appPreferences.openNotificationSettings();
  }, [available, bridge]);

  return {
    availability,
    openNotificationSettings,
    pending,
    preferences,
    showInSystemTray,
    update,
  };
}
