import { z } from "zod";
import { NativeOperationError } from "../ipc/operation-error";
import type { HostCommand } from "./host-preparation";

/** The native owner's receipt. Unknown fields are ignored; the fields Main reads keep their meaning. */
export const nativeReceiptSchema = z.object({
  version: z.number().int().min(1),
  requestId: z.string(),
  action: z.enum(["update", "reinstall", "uninstall"]),
  dataPolicy: z.enum(["preserve", "reset"]),
  targetApp: z.string().optional(),
  sourceApp: z.string().optional(),
  targetReleaseId: z.string().optional(),
  artifactSha256: z.string().optional(),
  artifactSize: z.number().optional(),
  stage: z.string(),
  outcome: z.enum(["pending", "failed", "succeeded", "superseded"]),
  failureMessage: z.string().optional(),
  /** `target_older_than_data`: the preflight refused before any effect. `host_start_failed`: bounded restore ended. */
  failureCode: z.string().max(128).optional(),
  retryable: z.boolean().optional(),
});
export type NativeReceipt = z.infer<typeof nativeReceiptSchema>;

/** The installed Host does not have the maintenance protocol, so it must update before this operation. */
export class HostMaintenanceIncompatibleError extends NativeOperationError {
  constructor(cause: unknown) {
    super(
      "Update Agent VMM Host in Local maintenance before changing this connection.",
      "OPERATION_FAILED",
      { cause }
    );
  }
}

/**
 * Probes whether an installed helper has the maintenance protocol. The native owner checks policy under its lock at
 * each mutation; an old helper without the protocol must never bypass that boundary, so the operations that can
 * conflict with maintenance (install, resume, enable, repair, update) require it. Drain, remove and revoke never
 * call it: an old Host may always be stopped or detached.
 *
 * One probe per helper path per user action or continuation step (`beginAction`), not one per mutation.
 */
export class MaintenanceCapabilityProbe {
  private readonly results = new Map<string, Promise<void>>();
  constructor(private readonly run: HostCommand) {}

  beginAction() {
    this.results.clear();
  }

  assert(path: string, serviceArgs: readonly string[]) {
    let result = this.results.get(path);
    if (!result) {
      result = (async () => {
        try {
          const value: unknown = JSON.parse(
            await this.run(path, ["maintenance-status", ...serviceArgs], "{}", 5_000)
          );
          if (value !== null) nativeReceiptSchema.parse(value);
        } catch (error) {
          throw new HostMaintenanceIncompatibleError(error);
        }
      })();
      this.results.set(path, result);
    }
    return result;
  }
}
