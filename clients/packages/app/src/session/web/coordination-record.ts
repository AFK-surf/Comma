import { z } from "zod";
import type { WebSessionCoordinationStorage } from "./coordination-ports";

export const webSessionCoordinationSchemaVersion = 1 as const;
export const webSessionLifecycleVersion = "1" as const;

const safeIntegerSchema = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const positiveSafeIntegerSchema = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
const boundedIdSchema = z.string().min(1).max(256);
const boundedOriginSchema = z.string().url().max(2_048);
const expectedSessionIdSchema = z.union([
  z.literal("unknown"),
  z.literal("none"),
  boundedIdSchema,
]);

export const webCookieStableStateSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("absent") }),
  z.strictObject({
    kind: z.literal("present"),
    sessionId: boundedIdSchema,
  }),
]);

const webCookieSettledStateSchema = z.discriminatedUnion("kind", [
  z.strictObject({
    kind: z.literal("stable"),
    state: webCookieStableStateSchema,
  }),
  z.strictObject({
    activeAuthAttemptId: boundedIdSchema,
    kind: z.literal("authenticating"),
    operationEpoch: positiveSafeIntegerSchema,
    state: z.strictObject({ kind: z.literal("absent") }),
  }),
]);

const recoveryExpectationSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("unknown_rebind") }),
  z.strictObject({
    kind: z.literal("exact_session"),
    sessionId: boundedIdSchema,
  }),
]);

const recoveryProgressSchema = z.discriminatedUnion("phase", [
  z.strictObject({
    phase: z.literal("ready"),
  }),
  z.strictObject({
    nextAttemptNotBeforeEpochMs: safeIntegerSchema,
    phase: z.literal("backoff"),
    problem: z.enum(["network_unavailable", "session_probe_unavailable"]),
  }),
  z.strictObject({
    ownerNonce: boundedIdSchema,
    phase: z.literal("in_flight"),
    startedAtEpochMs: safeIntegerSchema,
  }),
  z.strictObject({
    phase: z.literal("exhausted"),
    problem: z.enum([
      "network_unavailable",
      "protocol_mismatch",
      "session_probe_unavailable",
    ]),
  }),
]);

export const webCookieRecoveryTicketSchema = z.strictObject({
  attemptsStarted: safeIntegerSchema,
  deadlineAtEpochMs: safeIntegerSchema,
  expectation: recoveryExpectationSchema,
  maxAttempts: positiveSafeIntegerSchema,
  progress: recoveryProgressSchema,
  ticketId: boundedIdSchema,
});

const inFlightOperationSchema = z.discriminatedUnion("kind", [
  z.strictObject({
    expectedSessionId: expectedSessionIdSchema,
    kind: z.literal("reconcile"),
  }),
  z.strictObject({
    expectedSessionId: boundedIdSchema,
    kind: z.literal("product_unauthorized_reconcile"),
  }),
  z.strictObject({
    expectedSessionId: boundedIdSchema,
    kind: z.literal("sign_out"),
  }),
  z.strictObject({
    authAttemptId: boundedIdSchema,
    expectedSessionId: z.literal("none"),
    kind: z.literal("verify_email_login"),
  }),
  z.strictObject({
    authAttemptId: boundedIdSchema,
    expectedSessionId: z.literal("none"),
    kind: z.literal("complete_google_login"),
  }),
  z.strictObject({
    authAttemptId: boundedIdSchema,
    expectedSessionId: z.literal("none"),
    kind: z.literal("verify_google_link"),
  }),
  z.strictObject({
    authAttemptId: boundedIdSchema,
    expectedSessionId: z.literal("none"),
    kind: z.literal("start_guest_session"),
  }),
]);

const coordinationHeaderShape = {
  canonicalApiOrigin: boundedOriginSchema,
  cookieAuthorityId: boundedIdSchema,
  cookieGeneration: safeIntegerSchema,
  coordinationRevision: safeIntegerSchema,
  schemaVersion: z.literal(webSessionCoordinationSchemaVersion),
  writeNonce: boundedIdSchema,
};

export const webSessionCoordinationRecordSchema = z.discriminatedUnion("kind", [
  z.strictObject({
    ...coordinationHeaderShape,
    kind: z.literal("stable"),
    state: webCookieStableStateSchema,
  }),
  z.strictObject({
    ...coordinationHeaderShape,
    activeAuthAttemptId: boundedIdSchema,
    kind: z.literal("authenticating"),
    operationEpoch: positiveSafeIntegerSchema,
    state: z.strictObject({ kind: z.literal("absent") }),
  }),
  z.strictObject({
    ...coordinationHeaderShape,
    kind: z.literal("in_flight"),
    operation: inFlightOperationSchema,
    owner: z.strictObject({
      deadlineAtEpochMs: safeIntegerSchema,
      nonce: boundedIdSchema,
      operationEpoch: positiveSafeIntegerSchema,
      startedAtEpochMs: safeIntegerSchema,
    }),
    prior: webCookieSettledStateSchema,
  }),
  z.strictObject({
    ...coordinationHeaderShape,
    kind: z.literal("recovering"),
    ticket: webCookieRecoveryTicketSchema,
  }),
]);

export type WebCookieStableState = z.output<typeof webCookieStableStateSchema>;
export type WebCookieSettledState = z.output<typeof webCookieSettledStateSchema>;
export type WebCookieRecoveryTicket = z.output<typeof webCookieRecoveryTicketSchema>;
export type WebSessionCoordinationRecord = z.output<
  typeof webSessionCoordinationRecordSchema
>;
export type WebSessionInFlightOperation = Extract<
  WebSessionCoordinationRecord,
  { kind: "in_flight" }
>["operation"];

export type CoordinationRecordRead =
  | { kind: "missing" }
  | { kind: "corrupt"; raw: string }
  | { kind: "valid"; record: WebSessionCoordinationRecord };

export function webSessionCoordinationStorageKey(canonicalApiOrigin: string) {
  return `comma.session-lifecycle.v1:${encodeURIComponent(canonicalApiOrigin)}`;
}

export function webSessionCoordinationLockName(canonicalApiOrigin: string) {
  return `comma.session-lifecycle.v1:${canonicalApiOrigin}`;
}

export function webSessionCoordinationBroadcastName(canonicalApiOrigin: string) {
  return `comma.session-lifecycle.v1:${canonicalApiOrigin}`;
}

export function readWebSessionCoordinationRecord(
  storage: WebSessionCoordinationStorage,
  key: string,
  canonicalApiOrigin: string
): CoordinationRecordRead {
  const raw = storage.read(key);
  if (raw === null) {
    return { kind: "missing" };
  }

  try {
    const parsed = webSessionCoordinationRecordSchema.parse(JSON.parse(raw));
    if (parsed.canonicalApiOrigin !== canonicalApiOrigin) {
      return { kind: "corrupt", raw };
    }
    return { kind: "valid", record: parsed };
  } catch {
    return { kind: "corrupt", raw };
  }
}

export function writeWebSessionCoordinationRecord(
  storage: WebSessionCoordinationStorage,
  key: string,
  previous: WebSessionCoordinationRecord | undefined,
  nextValue: unknown
) {
  const next = webSessionCoordinationRecordSchema.parse(nextValue);
  assertWebSessionCoordinationTransition(previous, next);

  const encoded = JSON.stringify(next);
  storage.write(key, encoded);

  const readBack = storage.read(key);
  if (readBack !== encoded) {
    throw new Error("Web Session coordination record readback did not match.");
  }

  return webSessionCoordinationRecordSchema.parse(JSON.parse(readBack));
}

export function coordinationSettledState(
  record: WebSessionCoordinationRecord
): WebCookieSettledState | undefined {
  if (record.kind === "stable" || record.kind === "authenticating") {
    return settledStateFromRecord(record);
  }
  if (record.kind === "in_flight") {
    return record.prior;
  }
  return undefined;
}

export function coordinationSessionId(
  record: WebSessionCoordinationRecord
): string | null | undefined {
  if (
    record.kind === "in_flight" &&
    record.operation.kind === "product_unauthorized_reconcile"
  ) {
    // This marker is the global revocation commit for the captured lease. The
    // prior Session is retained only as recovery evidence; it is not a usable
    // Session in the marker's already-advanced Cookie generation.
    return undefined;
  }
  const settled = coordinationSettledState(record);
  if (!settled) {
    return undefined;
  }
  if (settled.kind === "authenticating" || settled.state.kind === "absent") {
    return null;
  }
  return settled.state.sessionId;
}

export function settledStateFromRecord(
  record: Extract<WebSessionCoordinationRecord, { kind: "authenticating" | "stable" }>
): WebCookieSettledState {
  if (record.kind === "stable") {
    return { kind: "stable", state: record.state };
  }
  return {
    activeAuthAttemptId: record.activeAuthAttemptId,
    kind: "authenticating",
    operationEpoch: record.operationEpoch,
    state: record.state,
  };
}

function assertWebSessionCoordinationTransition(
  previous: WebSessionCoordinationRecord | undefined,
  next: WebSessionCoordinationRecord
) {
  if (!previous) {
    if (next.kind !== "recovering") {
      throw new Error(
        "A new Web Cookie authority must begin with a persisted recovery ticket."
      );
    }
    return;
  }

  if (next.canonicalApiOrigin !== previous.canonicalApiOrigin) {
    throw new Error("Web Session coordination origin cannot change.");
  }
  if (next.writeNonce === previous.writeNonce) {
    throw new Error("Web Session coordination write nonce must change.");
  }

  if (next.cookieAuthorityId !== previous.cookieAuthorityId) {
    if (
      next.kind !== "recovering" ||
      next.ticket.expectation.kind !== "unknown_rebind"
    ) {
      throw new Error(
        "A replacement Web Cookie authority must begin with unknown recovery."
      );
    }
    if (next.coordinationRevision !== 0 || next.cookieGeneration !== 0) {
      throw new Error("A replacement Web Cookie authority must reset its axes.");
    }
    return;
  }

  if (next.coordinationRevision !== previous.coordinationRevision + 1) {
    throw new Error("Web Session coordination revision must advance exactly once.");
  }
  if (next.cookieGeneration < previous.cookieGeneration) {
    throw new Error("Web Cookie generation cannot regress.");
  }

  const previousSessionId = coordinationSessionId(previous);
  const nextSessionId = coordinationSessionId(next);
  if (
    previousSessionId !== undefined &&
    nextSessionId !== undefined &&
    previousSessionId !== nextSessionId &&
    next.cookieGeneration === previous.cookieGeneration
  ) {
    throw new Error(
      "Web Cookie Session presence cannot change without a new generation."
    );
  }
}
