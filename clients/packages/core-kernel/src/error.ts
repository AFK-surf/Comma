// The one error calls and topics report: `code` stable and machine-readable (a server's codes pass through as they
// are), `message` for people or logs, `status` the HTTP status when it came from a server.
import { Data } from "effect";

export class CoreError extends Error {
  code: string;
  status?: number;
  /// What else the server said, as it said it (its JSON error body), for a UI that words it.
  detail?: unknown;

  constructor(code: string, message: string, status?: number, detail?: unknown) {
    super(message);
    this.code = code;
    if (status !== undefined) this.status = status;
    if (detail !== undefined) this.detail = detail;
  }

  static invalid(message: string): CoreError {
    return new CoreError("invalid_params", message);
  }

  /// What a host said went wrong (no answer, a broken stream, a refused file).
  static host(error: HostError | string): CoreError {
    return new CoreError("host", typeof error === "string" ? error : error.message);
  }

  /// As it goes on the wire: `{ code, message, status?, detail? }`.
  toJSON(): ErrorBody {
    const out: ErrorBody = { code: this.code, message: this.message };
    if (this.status !== undefined) out.status = this.status;
    if (this.detail !== undefined) out.detail = this.detail;
    return out;
  }

  equals(other: CoreError): boolean {
    return (
      this.code === other.code &&
      this.message === other.message &&
      this.status === other.status
    );
  }
}

export type ErrorBody = {
  code: string;
  message: string;
  status?: number;
  detail?: unknown;
};

/// What a host says when what it was asked failed.
export class HostError extends Data.TaggedError("HostError")<{
  readonly message: string;
}> {
  constructor(message: string) {
    super({ message });
  }
}

/// Any failure as the core's error: a CoreError as it is, a host's as `host`, anything else `internal`.
export function asCoreError(error: unknown): CoreError {
  if (error instanceof CoreError) return error;
  if (error instanceof HostError) return CoreError.host(error);
  return new CoreError(
    "internal",
    error instanceof Error ? error.message : String(error)
  );
}

export type Result<T> = { ok: T } | { err: CoreError };
