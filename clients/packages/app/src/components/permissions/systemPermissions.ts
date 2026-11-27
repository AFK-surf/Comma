import { getNativeBridge, type SystemPermissionStatus } from "@comma/native-bridge";
import { useEffect, useRef, useState } from "react";
import { useCommaAppPreferences } from "../commaAppPreferences";
import { useComputerUsePermissions } from "../useComputerUsePermissions";

/** Every macOS permission Comma asks for, in the order Settings › Permissions lists them. */
export const systemPermissionIds = [
  "notifications",
  "location",
  "microphone",
  "accessibility",
  "screenRecording",
] as const;
export type SystemPermissionId = (typeof systemPermissionIds)[number];
/** The two grants the Comma Computer Use helper holds; one helper window grants both. */
export type ComputerUseGrantId = "accessibility" | "screenRecording";
/** A grant Comma itself holds and asks for alone. */
export type SingleGrantId = Exclude<SystemPermissionId, ComputerUseGrantId>;
export const isSingleGrant = (id: SystemPermissionId): id is SingleGrantId =>
  id !== "accessibility" && id !== "screenRecording";

/**
 * - `checking`: macOS has not answered yet.
 * - `notGranted`: macOS has not granted it, or could not be asked; the grant
 *   flow is offered either way, and it re-reads when the user comes back.
 * - `granted`: macOS reports the grant.
 */
export type PermissionStatus = "checking" | "notGranted" | "granted";

export interface SystemPermissionRow<
  Id extends SystemPermissionId = SystemPermissionId,
> {
  id: Id;
  status: PermissionStatus;
  /**
   * Not granted, and only System Settings can grant it now: macOS has already
   * refused it, so asking again would not show its prompt. The grant opens
   * the System Settings pane instead.
   */
  settingsOnly?: boolean;
  /**
   * macOS could not be asked at all (no addon, no bundle, a failed read), so
   * there is no answer to show and no prompt that could open: the row says
   * where to look instead of offering a grant that does nothing.
   */
  unreadable?: boolean;
}

export interface SystemPermissions {
  /** Electron on macOS, the only runtime that has all of them. */
  available: boolean;
  rows: readonly SystemPermissionRow[];
  /** The row whose grant flow is being opened. One flow opens at a time. */
  pendingId: SystemPermissionId | undefined;
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
   * notification, location or microphone prompt resolves with it instead.
   */
  grant(id: SystemPermissionId): Promise<boolean>;
  /** Asks macOS again for every answer. */
  refresh(): void;
}

/** Whether these permissions exist here at all, without reading anything from macOS. */
export function useSystemPermissionsAvailable(): boolean {
  return useComputerUsePermissions(false).available;
}

function resourceStatus(status: SystemPermissionStatus | undefined): PermissionStatus {
  if (status === undefined) return "checking";
  return status === "authorized" ? "granted" : "notGranted";
}

/**
 * The one source for Comma's macOS permissions: Settings › Permissions and the
 * onboarding's grant step both read it. While `active`, it reads the
 * computer-use grants on mount and whenever the window regains focus or turns
 * visible (the user coming back from System Settings). Notifications, location
 * and the microphone come with the app preferences snapshot, which Main
 * re-reads on the same two events. No timers.
 */
export function useSystemPermissions(active: boolean): SystemPermissions {
  const computerUse = useComputerUsePermissions(active);
  const appPreferences = useCommaAppPreferences();
  const available = computerUse.available && appPreferences.availability.notifications;
  const [pendingId, setPendingId] = useState<SystemPermissionId>();
  const pendingGrant = useRef<{ id: SystemPermissionId; opened: Promise<boolean> }>(
    undefined
  );
  const { refresh: refreshComputerUse } = computerUse;

  // The computer-use hook re-reads on window focus. Coming back from System
  // Settings can also surface only as the page turning visible again; its
  // one-request-in-flight gate folds the pair into a single helper read.
  useEffect(() => {
    if (!active || !available) return;
    const refreshWhenVisible = () => {
      if (document.visibilityState === "visible") refreshComputerUse();
    };
    document.addEventListener("visibilitychange", refreshWhenVisible);
    return () => document.removeEventListener("visibilitychange", refreshWhenVisible);
  }, [active, available, refreshComputerUse]);

  // A read that failed before any answer leaves the permissions unknown with
  // an error; before the first answer they are unknown without one.
  const computerUseStatus = (granted: boolean | undefined): PermissionStatus => {
    if (granted === undefined) {
      return computerUse.error === undefined ? "checking" : "notGranted";
    }
    return granted ? "granted" : "notGranted";
  };
  const preferences = appPreferences.preferences;
  // Main reads macOS's answer into every preferences snapshot: allowed, not
  // asked yet (`undetermined`), refused, or `unknown` when macOS could not be
  // asked, which is never shown as allowed. Until the first one, it is pending.
  const systemNotificationsStatus = preferences?.systemNotificationsStatus;
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
  const statuses: Record<SystemPermissionId, PermissionStatus> = {
    notifications: notificationsStatus,
    location: resourceStatus(preferences?.systemLocationStatus),
    microphone: resourceStatus(preferences?.systemMicrophoneStatus),
    accessibility: computerUseStatus(permissions?.accessibility),
    screenRecording: computerUseStatus(permissions?.screenRecording),
  };
  const unreadable: Record<SystemPermissionId, boolean> = {
    notifications: systemNotificationsStatus === "unknown",
    location: preferences?.systemLocationStatus === "unknown",
    microphone: preferences?.systemMicrophoneStatus === "unknown",
    accessibility: false,
    screenRecording: false,
  };
  const settingsOnly: Record<SystemPermissionId, boolean> = {
    notifications:
      notificationsStatus === "notGranted" &&
      systemNotificationsStatus !== "undetermined",
    location: preferences?.systemLocationStatus === "denied",
    microphone: preferences?.systemMicrophoneStatus === "denied",
    accessibility: false,
    screenRecording: false,
  };

  const grant = (id: SystemPermissionId): Promise<boolean> => {
    if (!available) return Promise.resolve(false);
    // One flow opens at a time. The same grant pressed again waits for the
    // flow already opening; another one opens once that flow has opened.
    const current = pendingGrant.current;
    if (current?.id === id) return current.opened;
    // The next render's grant: it reads the answers that flow brought.
    if (current) return current.opened.then(() => latestGrant.current(id));
    // Resolves whether macOS put a way to answer in front of the user. The
    // flows report failure in their result (a missing or crashed helper, a
    // prompt macOS declined to show) rather than by throwing.
    const open = async () => {
      setPendingId(id);
      try {
        const bridge = getNativeBridge();
        switch (id) {
          case "notifications": {
            // macOS asks the user itself while it has not asked about Comma
            // yet. After a refusal only System Settings › Notifications can
            // allow it, so that pane opens on Comma's own entry.
            if (systemNotificationsStatus === "undetermined") {
              // Still undetermined afterwards: macOS answered without asking.
              const status = await appPreferences.requestNotificationAuthorization();
              return status !== "undetermined";
            }
            const settings = await appPreferences.openNotificationSettings();
            return settings.opened;
          }
          // Main prompts while macOS has not asked, and opens the System
          // Settings pane once it is off; either way it publishes the new
          // status. `unknown`: nothing could be asked.
          case "location":
            return (
              (await bridge.appPreferences.requestLocationAuthorization()) !== "unknown"
            );
          case "microphone":
            return (
              (await bridge.appPreferences.requestMicrophoneAuthorization()) !==
              "unknown"
            );
          case "accessibility":
          case "screenRecording": {
            // Both computer-use grants share one flow: the Computer Use
            // helper's window lists Accessibility and Screen Recording, and
            // each Allow there opens its System Settings pane. The helper
            // takes focus, so coming back re-reads both. The flow is opened
            // directly because the hook's open() is dropped while a focus
            // re-read is still in flight.
            const flow = await bridge.computerUse.openPermissionFlow();
            if (!flow.ok) console.error("[permissions] flow did not open", flow.error);
            return flow.ok;
          }
        }
      } catch (error) {
        console.error("[permissions] flow did not open", error);
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

  const latestGrant = useRef(grant);
  latestGrant.current = grant;

  const refresh = () => {
    if (!available) return;
    refreshComputerUse();
    // Main re-reads notifications, location and the microphone around every
    // state read and publishes a change through the state event the
    // preferences follow.
    void getNativeBridge()
      .appPreferences.state.get()
      .catch(() => undefined);
  };

  return {
    available,
    unreadable: computerUse.error !== undefined && permissions === undefined,
    rows: systemPermissionIds.map((id) => ({
      id,
      status: statuses[id],
      ...(settingsOnly[id] ? { settingsOnly: true } : {}),
      ...(unreadable[id] ? { unreadable: true } : {}),
    })),
    pendingId,
    reading: computerUse.pending,
    grant,
    refresh,
  };
}
