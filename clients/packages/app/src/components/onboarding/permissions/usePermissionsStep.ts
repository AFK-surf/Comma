import {
  useSystemPermissions,
  useSystemPermissionsAvailable,
  type PermissionStatus,
  type SystemPermissionRow,
} from "../../permissions/systemPermissions";
import { permissionIds, type PermissionId } from "../onboardingSetup";

export { permissionIds, type PermissionId, type PermissionStatus };

export type PermissionRowState = SystemPermissionRow<PermissionId>;

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
 * macOS: the computer-use capability's own rule (Electron on macOS).
 */
export function usePermissionsStepAvailable(): boolean {
  return useSystemPermissionsAvailable();
}

const isStepRow = (row: SystemPermissionRow): row is PermissionRowState =>
  (permissionIds as readonly string[]).includes(row.id);

/**
 * The onboarding's grant-permissions step: the three permissions it asks for,
 * read from the same source as Settings › Permissions. Mount it with the step.
 */
export function usePermissionsStep(): PermissionsStep {
  const permissions = useSystemPermissions(true);
  const pendingId = permissions.pendingId;
  return {
    available: permissions.available,
    unreadable: permissions.unreadable,
    rows: permissions.rows.filter(isStepRow),
    pendingId:
      pendingId && (permissionIds as readonly string[]).includes(pendingId)
        ? (pendingId as PermissionId)
        : undefined,
    reading: permissions.reading,
    grant: permissions.grant,
    refresh: permissions.refresh,
  };
}
