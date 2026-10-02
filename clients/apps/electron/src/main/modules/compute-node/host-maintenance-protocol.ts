import { z } from "zod";
import type { HostCommand } from "./host-preparation";

export const nativeReceiptSchema = z.object({
  version: z.literal(1),
  requestId: z.string(),
  action: z.enum(["update", "reinstall", "uninstall"]),
  dataPolicy: z.enum(["preserve", "reset"]),
  targetApp: z.string(),
  sourceApp: z.string().optional(),
  targetReleaseId: z.string().optional(),
  artifactSha256: z.string().optional(),
  artifactSize: z.number().optional(),
  supersedesRequestId: z.string().optional(),
  supersededByRequestId: z.string().optional(),
  stage: z.enum([
    "accepted",
    "stopping",
    "resetting",
    "removing",
    "replacing",
    "restoring",
    "verifying",
    "complete",
  ]),
  outcome: z.enum(["pending", "failed", "succeeded", "superseded"]),
  failureMessage: z.string().optional(),
});

/** Probe compatibility only. The native owner checks policy under its lock at
 * each mutation; an old helper must never bypass that boundary.
 */
export async function assertMaintenanceCapable(
  path: string,
  run: HostCommand,
  serviceArgs: readonly string[]
) {
  try {
    const value: unknown = JSON.parse(
      await run(path, ["maintenance-status", ...serviceArgs], "{}", 5_000)
    );
    if (value !== null) nativeReceiptSchema.parse(value);
  } catch (error) {
    throw new Error(
      "Update Agent VMM Host in Local maintenance before changing this connection.",
      { cause: error }
    );
  }
}
