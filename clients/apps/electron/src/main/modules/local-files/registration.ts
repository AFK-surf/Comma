import type { LocalFileRegistrationFailure } from "@comma/core/contract";
import { getCurrentNativeSessionAdmission } from "../session/native-session-admission";
import {
  LocalFileSnapshotError,
  type LocalFileSnapshotStore,
  type LocalFileSnapshot,
} from "./snapshot-store";

export interface LocalFileRouteRegistrar {
  /**
   * Advisory hint that a pick for this workspace is underway, so the
   * workspace connector can start connecting while the native dialog is open.
   */
  prewarm?(workspaceId: string): void;
  /** `intakeId`: the chat intake the file is for (the core checks it is still the draft's before each request). */
  register(
    workspaceId: string,
    snapshot: LocalFileSnapshot,
    assertRegistrationAllowed: () => void,
    intakeId?: string
  ): Promise<void>;
}

/** A call to the client core (Main's own client). */
export type CoreCall = (name: string, params: unknown) => Promise<unknown>;

export interface LocalFileRegistrationTarget {
  connectorRunId: string;
  deviceId: string;
  localFileIndexVersion: 2;
}

export type ResolveLocalFileRegistrationTarget = (
  workspaceId: string,
  options: { signal: AbortSignal }
) => Promise<LocalFileRegistrationTarget | null>;

/**
 * Distinguishes a request that definitely never created a route from a
 * dispatched create whose response may have been lost. Main retains bytes
 * only for the latter so an accepted server route never points at deleted
 * local content.
 */
export class LocalFileRouteRegistrationError extends LocalFileSnapshotError {
  constructor(
    readonly outcome: "ambiguous" | "rejected",
    message = "The selected file could not be registered.",
    readonly remediation?: "reissue_connector_token",
    readonly retryable = false
  ) {
    super("local_file_unavailable", message);
    this.name = "LocalFileRouteRegistrationError";
  }
}

/**
 * A local file's route, registered by the client core (`localFiles.register`: the request, its retry and what its
 * failure means for the bytes). Main resolves the exact V2 Connector target it runs, checks the caller's fence, and
 * marks the snapshot registered once the core answers. Nothing but the workspace, the opaque ref and the target goes
 * to the core: no host path, no bytes.
 */
export class LocalFileRouteRegistrationService implements LocalFileRouteRegistrar {
  readonly #call: CoreCall;
  readonly #onConnectorReconfigurationRequired:
    | ((workspaceId: string) => void)
    | undefined;
  readonly #prewarmTarget: ((workspaceId: string) => void) | undefined;
  readonly #resolveTarget: ResolveLocalFileRegistrationTarget;
  readonly #store: Pick<LocalFileSnapshotStore, "markRegistered">;

  constructor({
    call,
    onConnectorReconfigurationRequired,
    prewarmTarget,
    resolveTarget,
    store,
  }: {
    call: CoreCall;
    onConnectorReconfigurationRequired?: (workspaceId: string) => void;
    prewarmTarget?: (workspaceId: string) => void;
    resolveTarget: ResolveLocalFileRegistrationTarget;
    store: Pick<LocalFileSnapshotStore, "markRegistered">;
  }) {
    this.#call = call;
    this.#onConnectorReconfigurationRequired = onConnectorReconfigurationRequired;
    this.#prewarmTarget = prewarmTarget;
    this.#resolveTarget = resolveTarget;
    this.#store = store;
  }

  prewarm(workspaceId: string): void {
    const normalizedWorkspaceId = workspaceId.trim();
    if (!normalizedWorkspaceId || normalizedWorkspaceId.length > 160) return;
    this.#prewarmTarget?.(normalizedWorkspaceId);
  }

  async register(
    workspaceId: string,
    snapshot: LocalFileSnapshot,
    assertRegistrationAllowed: () => void,
    intakeId?: string
  ) {
    const { credential } = getCurrentNativeSessionAdmission();
    const normalizedWorkspaceId = workspaceId.trim();
    if (!normalizedWorkspaceId || normalizedWorkspaceId.length > 160) {
      throw unavailable("rejected");
    }

    // Resolution ensures the Main-owned workspace connector is running and
    // waits, bounded, for it to connect; a null target means it could not
    // become ready under the current Session credential.
    const target = await this.#resolveTarget(normalizedWorkspaceId, {
      signal: credential.signal,
    });
    const deviceId = target?.deviceId.trim();
    const connectorRunId = target?.connectorRunId.trim();
    if (
      !deviceId ||
      !connectorRunId ||
      connectorRunId.length > 160 ||
      target?.localFileIndexVersion !== 2
    ) {
      throw unavailable(
        "rejected",
        "This workspace's Comma Connector is not ready yet. Select the file again to retry.",
        undefined,
        true
      );
    }
    // Resolution crossed async boundaries: the caller's fence holds still, or nothing goes.
    try {
      assertRegistrationAllowed();
    } catch {
      throw unavailable("rejected");
    }
    try {
      await this.#call("localFiles.register", {
        workspace: normalizedWorkspaceId,
        localFileRef: snapshot.localFileRef,
        connectorRunId,
        deviceId,
        ...(intakeId ? { intakeId } : {}),
      });
    } catch (error) {
      const { code, detail, message } = (error ?? {}) as {
        code?: unknown;
        detail?: Partial<LocalFileRegistrationFailure>;
        message?: string;
      };
      if (code === "local_file_unavailable" && detail?.outcome) {
        if (detail.remediation === "reissue_connector_token")
          // Recycling restarts the workspace connector with a freshly minted
          // token in the background, so the user's next selection succeeds
          // without any manual reconnect step.
          this.#onConnectorReconfigurationRequired?.(normalizedWorkspaceId);
        throw unavailable(
          detail.outcome,
          message,
          detail.remediation,
          detail.retryable ?? detail.outcome === "ambiguous"
        );
      }
      // The core refused the call itself: nothing went out. Without its answer (it went away), a request may have.
      throw unavailable(typeof code === "string" ? "rejected" : "ambiguous");
    }

    try {
      await this.#store.markRegistered(snapshot.localFileRef);
    } catch {
      // The authenticated server already returned success. A local
      // transition/fsync failure must not delete the bytes behind that
      // durable route; bounded reconciliation/cleanup owns settlement.
      throw unavailable("ambiguous", undefined, undefined, false);
    }
  }
}

function unavailable(
  outcome: "ambiguous" | "rejected",
  message?: string,
  remediation?: "reissue_connector_token",
  retryable = outcome === "ambiguous"
) {
  return new LocalFileRouteRegistrationError(outcome, message, remediation, retryable);
}
