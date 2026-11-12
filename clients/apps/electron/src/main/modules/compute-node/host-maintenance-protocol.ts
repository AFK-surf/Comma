import { z } from "zod";
import { NativeOperationError } from "../ipc/operation-error";

const MIN_CONTRACT_VERSION = 1;
const CONTRACT_VERSION = 1;

/** Main interprets only this helper contract range. Other diagnostic fields remain readable. */
export function helperContractFailure(
  value: unknown
): "too_old" | "too_new" | undefined {
  const version =
    value && typeof value === "object" && "contractVersion" in value
      ? value.contractVersion
      : undefined;
  if (!Number.isSafeInteger(version) || Number(version) < MIN_CONTRACT_VERSION)
    return "too_old";
  return Number(version) > CONTRACT_VERSION ? "too_new" : undefined;
}

export function assertHelperContract(value: unknown) {
  const side = helperContractFailure(value);
  if (side) throw new HostMaintenanceIncompatibleError(undefined, side);
}

/** The native owner's receipt. Unknown fields are ignored; the fields Main reads keep their meaning. */
export const nativeReceiptSchema = z.object({
  contractVersion: z.number().int().optional(),
  version: z.number().int().min(1),
  requestId: z.string(),
  action: z.enum(["update", "reinstall", "uninstall"]),
  dataPolicy: z.enum(["preserve", "reset"]),
  targetApp: z.string().optional(),
  sourceApp: z.string().optional(),
  targetReleaseId: z.string().optional(),
  stage: z.string(),
  outcome: z.enum(["pending", "failed", "succeeded", "superseded"]),
  failureMessage: z.string().optional(),
  /** `target_older_than_data`: the preflight refused before any effect. `host_start_failed`: bounded restore ended. */
  failureCode: z.string().max(128).optional(),
  retryable: z.boolean().optional(),
});
export type NativeReceipt = z.infer<typeof nativeReceiptSchema>;

/** Actionable receipts must use the contract Main can interpret. */
export function parseNativeReceipt(value: unknown): NativeReceipt {
  if (value !== null) assertHelperContract(value);
  return nativeReceiptSchema.parse(value);
}

/** Main cannot interpret this helper's maintenance contract. */
export class HostMaintenanceIncompatibleError extends NativeOperationError {
  constructor(
    cause: unknown,
    readonly side: "too_old" | "too_new" = "too_old"
  ) {
    super(
      side === "too_new"
        ? "Update Comma to use this Agent VMM Host component."
        : "Update Agent VMM Host in Local maintenance before changing this connection.",
      "OPERATION_FAILED",
      { cause }
    );
  }
}
