import { getNativeBridge } from "@comma/native-bridge";
import { useEffect, useRef, useState } from "react";
import { useCommaAppPreferences } from "../../commaAppPreferences";
import { useComputerUsePermissions } from "../../useComputerUsePermissions";
import { permissionIds, type PermissionId } from "../onboardingSetup";

export { permissionIds, type PermissionId };

/**
 * - `checking`: macOS has not answered yet.
 * - `notGranted`: macOS has not granted it, or could not be asked; the grant
 *   flow is offered either way, and it re-reads when the user comes back.
 * - `granted`: macOS reports the grant.
 */
export type PermissionStatus = "checking" | "notGranted" | "granted";

export interface PermissionRowState {
  id: PermissionId;
  status: PermissionStatus;
  /**
   * Not granted, and only System Settings can grant it now: macOS has refused
   * notifications, so asking again would not show its prompt.
   */
  settingsOnly?: boolean;
}

export interface PermissionsStep {
  /** Electron on macOS, the only runtime with all three capabilities. */
  available: boolean;
  rows: readonly PermissionRowState[];
  /** The row whose grant flow is being opened. One flow opens at a time. */
  pendingId: PermissionId | undefined;
  /** A read of the computer-use grants is in flight. */
  reading: boolean;
  /**
   * The computer-use grants could not be read at all (the helper is missing or
   * failed): their rows say so rather than offering an Allow that cannot work.
   */
  unreadable: boolean;
  /**
   * Opens the grant flow for `id` and resolves once it is open. The answer
   * arrives later, when the window regains focus or becomes visible again; a
   * notification prompt resolves with it instead.
   */
  grant(id: PermissionId): Promise<boolean>;
  /** Asks macOS again for all three answers. */
  refresh(): void;
}

/**
 * Whether the permissions step exists at all, without reading anything from
 * macOS: the computer-use capability's own rule (Electron on macOS). The
 * notification readback exists on every Electron OS, so this is the binding one.
 */
export function usePermissionsStepAvailable(): boolean {
  return useComputerUsePermissions(false).available;
}

/**
 * Live state and actions for the onboarding's grant-permissions step. Mount it
 * with the step: it reads the computer-use permissions once on mount and again
 * whenever the window regains focus or becomes visible (the user coming back
 * from System Settings). Notification authorization follows the app
 * preferences snapshot, which re-reads on the same two events. No timers.
 */
export function usePermissionsStep(): PermissionsStep {
  const computerUse = useComputerUsePermissions(true);
  const appPreferences = useCommaAppPreferences();
  const available = computerUse.available && appPreferences.availability.notifications;
  const [pendingId, setPendingId] = useState<PermissionId>();
  const pendingGrant = useRef<{ id: PermissionId; opened: Promise<boolean> }>(
    undefined
  );
  const { refresh: refreshComputerUse } = computerUse;

  // The computer-use hook re-reads on window focus. Coming back from System
  // Settings can also surface only as the page turning visible again; its
  // one-request-in-flight gate folds the pair into a single helper read.
  useEffect(() => {
    if (!available) return;
    const refreshWhenVisible = () => {
      if (document.visibilityState === "visible") refreshComputerUse();
    };
    document.addEventListener("visibilitychange", refreshWhenVisible);
    return () => document.removeEventListener("visibilitychange", refreshWhenVisible);
  }, [available, refreshComputerUse]);

  // A read that failed before any answer leaves the permissions unknown with
  // an error; before the first answer they are unknown without one.
  const computerUseStatus = (granted: boolean | undefined): PermissionStatus => {
    if (granted === undefined) {
      return computerUse.error === undefined ? "checking" : "notGranted";
    }
    return granted ? "granted" : "notGranted";
  };
  // Main reads macOS's answer into every preferences snapshot: allowed, not
  // asked yet (`undetermined`), refused, or `unknown` when macOS could not be
  // asked, which is never shown as allowed. Until the first one, it is pending.
  const systemNotificationsStatus =
    appPreferences.preferences?.systemNotificationsStatus;
  const notificationsStatus: PermissionStatus =
    systemNotificationsStatus === undefined
      ? "checking"
      : systemNotificationsStatus === "available"
        ? "granted"
        : "notGranted";
  // A re-read that fails keeps the last answer here: one failed read (the
  // helper busy, the user coming back mid-launch) does not take back a grant
  // macOS already reported.
  const lastPermissions = useRef(computerUse.permissions);
  if (computerUse.permissions) lastPermissions.current = computerUse.permissions;
  const permissions = computerUse.permissions ?? lastPermissions.current;
  const statuses: Record<PermissionId, PermissionStatus> = {
    accessibility: computerUseStatus(permissions?.accessibility),
    screenRecording: computerUseStatus(permissions?.screenRecording),
    notifications: notificationsStatus,
  };

  const grant = (id: PermissionId): Promise<boolean> => {
    if (!available) return Promise.resolve(false);
    // One flow opens at a time. The same grant pressed again waits for the
    // flow already opening; another one opens once that flow has opened.
    const current = pendingGrant.current;
    if (current?.id === id) return current.opened;
    if (current) return current.opened.then(() => grant(id));
    // Resolves whether macOS put a way to answer in front of the user. The
    // flows report failure in their result (a missing or crashed helper, a
    // prompt macOS declined to show) rather than by throwing.
    const open = async () => {
      setPendingId(id);
      try {
        if (id === "notifications") {
          // macOS asks the user itself while it has not asked about Comma yet.
          // After a refusal only System Settings › Notifications can allow it,
          // so that pane opens on Comma's own entry.
          if (systemNotificationsStatus === "undetermined") {
            // Still undetermined afterwards: macOS answered without asking.
            const status = await appPreferences.requestNotificationAuthorization();
            return status !== "undetermined";
          }
          const settings = await appPreferences.openNotificationSettings();
          return settings.opened;
        }
        // Both computer-use grants share one flow: the Computer Use helper's
        // window lists Accessibility and Screen Recording, and each Allow
        // there opens its System Settings pane. The helper takes focus, so
        // coming back re-reads both. The flow is opened directly because the
        // hook's open() is dropped while a focus re-read is still in flight.
        const flow = await getNativeBridge().computerUse.openPermissionFlow();
        if (!flow.ok)
          console.error("[onboarding] permission flow did not open", flow.error);
        return flow.ok;
      } catch (error) {
        console.error("[onboarding] permission flow did not open", error);
        return false;
      } finally {
        pendingGrant.current = undefined;
        setPendingId(undefined);
      }
    };
    const opened = open();
    pendingGrant.current = { id, opened };
    return opened;
  };

  const refresh = () => {
    if (!available) return;
    refreshComputerUse();
    // Main re-reads the notification authorization around every state read
    // and publishes a change through the state event the preferences follow.
    void getNativeBridge()
      .appPreferences.state.get()
      .catch(() => undefined);
  };

  return {
    available,
    unreadable: computerUse.error !== undefined && permissions === undefined,
    rows: permissionIds.map((id) => ({
      id,
      status: statuses[id],
      ...(id === "notifications" &&
      statuses[id] === "notGranted" &&
      systemNotificationsStatus !== "undetermined"
        ? { settingsOnly: true }
        : {}),
    })),
    pendingId,
    reading: computerUse.pending,
    grant,
    refresh,
  };
}
