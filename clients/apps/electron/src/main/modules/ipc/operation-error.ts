/** Only Main owners may select a sanitized, user-facing operation failure. */
export class NativeOperationError extends Error {
  constructor(
    message: string,
    readonly code:
      | "OPERATION_FAILED"
      | "COMPUTE_SETUP_FAILED"
      | "COMPUTE_SETUP_UNKNOWN"
      | "COMPUTE_CLOUD_UNAVAILABLE"
      | "COMPUTE_CONNECTION_FAILED"
      | "COMPUTE_RECOVERY_UNVERIFIED" = "OPERATION_FAILED",
    options?: ErrorOptions
  ) {
    super(message, options);
    this.name = "NativeOperationError";
  }
}
