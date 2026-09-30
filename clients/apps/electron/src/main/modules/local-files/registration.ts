import { z } from "zod";
import { getCurrentNativeSessionAdmission } from "../session/native-session-admission";
import {
  LocalFileSnapshotError,
  LocalFileSnapshotStore,
  type LocalFileSnapshot,
} from "./snapshot-store";

const registrationResponseSchema = z
  .object({
    local_file_ref: z.string().regex(/^lfi1_[A-Za-z0-9_-]{43}$/),
    state: z.literal("registered"),
  })
  .strict();

const ownerUpgradeRequiredResponseSchema = z
  .object({
    action: z.literal("reissue_connector_token"),
    connector_token_endpoint: z.string().min(1),
    error: z.literal("connector_reconfiguration_required"),
    reason: z.literal("connector_owner_missing"),
  })
  .strict();

const REGISTRATION_TIMEOUT_MS = 15_000;

export interface LocalFileRouteRegistrar {
  /**
   * Advisory hint that a pick for this workspace is underway, so the
   * workspace connector can start connecting while the native dialog is open.
   */
  prewarm?(workspaceId: string): void;
  register(
    workspaceId: string,
    snapshot: LocalFileSnapshot,
    assertRegistrationAllowed: () => void
  ): Promise<void>;
}

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
 * Main-only authenticated ref registration. The request carries the product
 * workspace, opaque ref, and the exact V2 Connector status target observed by
 * Main. It never carries a host path, file bytes, or connection generation.
 * The server derives the owner from the exact Session credential, authorizes
 * registration only against the current Registry run, and derives the read
 * generation later at admission time.
 */
export class LocalFileRouteRegistrationService implements LocalFileRouteRegistrar {
  readonly #fetch: typeof fetch;
  readonly #onConnectorReconfigurationRequired:
    | ((workspaceId: string) => void)
    | undefined;
  readonly #prewarmTarget: ((workspaceId: string) => void) | undefined;
  readonly #resolveTarget: ResolveLocalFileRegistrationTarget;
  readonly #store: LocalFileSnapshotStore;

  constructor({
    fetch: fetchImplementation = fetch,
    onConnectorReconfigurationRequired,
    prewarmTarget,
    resolveTarget,
    store,
  }: {
    fetch?: typeof fetch;
    onConnectorReconfigurationRequired?: (workspaceId: string) => void;
    prewarmTarget?: (workspaceId: string) => void;
    resolveTarget: ResolveLocalFileRegistrationTarget;
    store: LocalFileSnapshotStore;
  }) {
    this.#fetch = fetchImplementation;
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
    assertRegistrationAllowed: () => void
  ) {
    const admission = getCurrentNativeSessionAdmission();
    const credential = admission.credential;
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

    const url = new URL(
      `/v1/comma/workspaces/${encodeURIComponent(normalizedWorkspaceId)}/local-file-refs`,
      credential.audience
    );
    if (url.origin !== credential.audience) throw unavailable("rejected");

    const body = JSON.stringify({
      connector_run_id: connectorRunId,
      local_file_index_version: 2,
      local_file_ref: snapshot.localFileRef,
      stable_device_id: deviceId,
    });
    let mayHaveCommitted = false;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      if (credential.signal.aborted) {
        throw unavailable(mayHaveCommitted ? "ambiguous" : "rejected");
      }
      // resolveTarget and prior attempts cross async boundaries. Revalidate
      // the exact Chat intake claim after all of them and immediately before
      // every possible HTTP dispatch.
      try {
        assertRegistrationAllowed();
      } catch {
        // Before the first dispatch this is a definite local rejection and
        // the draft may be released. After an ambiguous dispatch, preserve
        // the snapshot even though the stale fence forbids any retry.
        throw unavailable(mayHaveCommitted ? "ambiguous" : "rejected");
      }
      let response: Response;
      try {
        response = await this.#fetch(url, {
          body,
          credentials: "omit",
          headers: {
            accept: "application/json",
            authorization: `Bearer ${credential.token}`,
            "content-type": "application/json",
          },
          method: "POST",
          redirect: "manual",
          signal: AbortSignal.any([
            credential.signal,
            AbortSignal.timeout(REGISTRATION_TIMEOUT_MS),
          ]),
        });
      } catch {
        // Once a request was dispatched, a transport failure cannot prove
        // that the server did not commit it. A later definite rejection must
        // not erase that ambiguity and authorize deletion of the local bytes.
        mayHaveCommitted = true;
        if (attempt === 0 && !credential.signal.aborted) continue;
        throw unavailable("ambiguous");
      }
      if (!response.ok || response.status < 200 || response.status >= 300) {
        if (response.status >= 500) {
          mayHaveCommitted = true;
          if (attempt === 0) continue;
        }
        const ownerUpgradeRequired =
          response.status === 409
            ? ownerUpgradeRequiredResponseSchema.safeParse(
                await response.json().catch(() => null)
              )
            : undefined;
        if (
          ownerUpgradeRequired?.success &&
          ownerUpgradeRequired.data.connector_token_endpoint ===
            `/v1/comma/workspaces/${encodeURIComponent(normalizedWorkspaceId)}/connector-token`
        ) {
          // Recycling restarts the workspace connector with a freshly minted
          // token in the background, so the user's next selection succeeds
          // without any manual reconnect step.
          this.#onConnectorReconfigurationRequired?.(normalizedWorkspaceId);
          throw unavailable(
            mayHaveCommitted ? "ambiguous" : "rejected",
            "Reconnect this workspace's Comma Connector with a newly issued token, then select the file again.",
            "reissue_connector_token",
            true
          );
        }
        throw unavailable(
          mayHaveCommitted ? "ambiguous" : "rejected",
          undefined,
          undefined,
          response.status === 408 || response.status === 429 || response.status >= 500
        );
      }
      const responseBody = await response.json().catch(() => null);
      const parsed = registrationResponseSchema.safeParse(responseBody);
      if (!parsed.success || parsed.data.local_file_ref !== snapshot.localFileRef) {
        mayHaveCommitted = true;
        if (attempt === 0) continue;
        throw unavailable("ambiguous");
      }

      try {
        await this.#store.markRegistered(snapshot.localFileRef);
      } catch {
        // The authenticated server already returned success. A local
        // transition/fsync failure must not delete the bytes behind that
        // durable route; bounded reconciliation/cleanup owns settlement.
        throw unavailable("ambiguous", undefined, undefined, false);
      }
      return;
    }
    throw unavailable("ambiguous");
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
