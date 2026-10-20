// What chat's calls share: their params checked, and their errors as the core's.
import { CoreError } from "@comma/core-kernel";
import type { z } from "zod";
import { StaleChatSessionError } from "./coordinator/entries/sessionBoundary.ts";

/** A call's params through `schema`, or the call fails as invalid. */
export function parse<S extends z.ZodType>(schema: S, params: unknown): z.output<S> {
  const out = schema.safeParse(params ?? {});
  if (!out.success)
    throw CoreError.invalid(out.error.issues[0]?.message ?? "invalid params");
  return out.data;
}

/** A chat error as the core's. */
export function asCoreError(error: unknown): CoreError {
  return error instanceof CoreError
    ? error
    : error instanceof StaleChatSessionError
      ? new CoreError("session_changed", error.message)
      : new CoreError(
          "chat_refused",
          error instanceof Error ? error.message : String(error),
          (error as { status?: number }).status
        );
}
