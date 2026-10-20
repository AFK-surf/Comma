// The web session's coordination record: what the core knows of the origin's session Cookie (which JavaScript cannot
// read), kept in the host's device storage so the core that runs next (another tab's worker, after this one's tab
// closed) starts from it. Its shape and transition rules are those the page adapter (retired) kept in localStorage,
// so a record an older build wrote means the same here. No credential and no person's details are in it: the Cookie authority (`cookieAuthorityId`, a random id
// that is replaced when nothing is known of the Cookie), its generation (counted up each time the Cookie may name
// another session), the revision of the record itself, what is under way (`in_flight`, with its deadline and the state
// before it) and the recovery ticket (bounded attempts within a window, a backoff between them).
import { z } from "zod";

export const WEB_SESSION_LIFECYCLE_VERSION = "1";

const safeInteger = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const positiveSafeInteger = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
const boundedId = z.string().min(1).max(256);
const boundedOrigin = z.string().url().max(2_048);
const expectedSessionId = z.union([z.literal("unknown"), z.literal("none"), boundedId]);

const stableState = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("absent") }),
  z.strictObject({ kind: z.literal("present"), sessionId: boundedId }),
]);

const settledState = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("stable"), state: stableState }),
  z.strictObject({
    activeAuthAttemptId: boundedId,
    kind: z.literal("authenticating"),
    operationEpoch: positiveSafeInteger,
    state: z.strictObject({ kind: z.literal("absent") }),
  }),
]);

const recoveryExpectation = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("unknown_rebind") }),
  z.strictObject({ kind: z.literal("exact_session"), sessionId: boundedId }),
]);

const recoveryProgress = z.discriminatedUnion("phase", [
  z.strictObject({ phase: z.literal("ready") }),
  z.strictObject({
    nextAttemptNotBeforeEpochMs: safeInteger,
    phase: z.literal("backoff"),
    problem: z.enum(["network_unavailable", "session_probe_unavailable"]),
  }),
  z.strictObject({
    ownerNonce: boundedId,
    phase: z.literal("in_flight"),
    startedAtEpochMs: safeInteger,
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

const recoveryTicket = z.strictObject({
  attemptsStarted: safeInteger,
  deadlineAtEpochMs: safeInteger,
  expectation: recoveryExpectation,
  maxAttempts: positiveSafeInteger,
  progress: recoveryProgress,
  ticketId: boundedId,
});

const inFlightOperation = z.discriminatedUnion("kind", [
  z.strictObject({ expectedSessionId, kind: z.literal("reconcile") }),
  z.strictObject({
    expectedSessionId: boundedId,
    kind: z.literal("product_unauthorized_reconcile"),
  }),
  z.strictObject({ expectedSessionId: boundedId, kind: z.literal("sign_out") }),
  z.strictObject({
    authAttemptId: boundedId,
    expectedSessionId: z.literal("none"),
    kind: z.literal("verify_email_login"),
  }),
  z.strictObject({
    authAttemptId: boundedId,
    expectedSessionId: z.literal("none"),
    kind: z.literal("complete_google_login"),
  }),
  z.strictObject({
    authAttemptId: boundedId,
    expectedSessionId: z.literal("none"),
    kind: z.literal("verify_google_link"),
  }),
  z.strictObject({
    authAttemptId: boundedId,
    expectedSessionId: z.literal("none"),
    kind: z.literal("start_guest_session"),
  }),
]);

const header = {
  canonicalApiOrigin: boundedOrigin,
  cookieAuthorityId: boundedId,
  cookieGeneration: safeInteger,
  coordinationRevision: safeInteger,
  schemaVersion: z.literal(1),
  writeNonce: boundedId,
};

export const webSessionRecordSchema = z.discriminatedUnion("kind", [
  z.strictObject({ ...header, kind: z.literal("stable"), state: stableState }),
  z.strictObject({
    ...header,
    activeAuthAttemptId: boundedId,
    kind: z.literal("authenticating"),
    operationEpoch: positiveSafeInteger,
    state: z.strictObject({ kind: z.literal("absent") }),
  }),
  z.strictObject({
    ...header,
    kind: z.literal("in_flight"),
    operation: inFlightOperation,
    owner: z.strictObject({
      deadlineAtEpochMs: safeInteger,
      nonce: boundedId,
      operationEpoch: positiveSafeInteger,
      startedAtEpochMs: safeInteger,
    }),
    prior: settledState,
  }),
  z.strictObject({ ...header, kind: z.literal("recovering"), ticket: recoveryTicket }),
]);

export type WebSessionRecord = z.output<typeof webSessionRecordSchema>;
export type SettledRecord = Extract<
  WebSessionRecord,
  { kind: "authenticating" | "stable" }
>;
export type InFlightRecord = Extract<WebSessionRecord, { kind: "in_flight" }>;
export type RecoveringRecord = Extract<WebSessionRecord, { kind: "recovering" }>;
export type InFlightOperation = InFlightRecord["operation"];
export type SettledState = z.output<typeof settledState>;

/** The record's body: what a write gives, the header (origin, authority, axes, nonce) added by it. */
export type RecordBody<R extends WebSessionRecord = WebSessionRecord> =
  R extends WebSessionRecord
    ? Omit<
        R,
        | "canonicalApiOrigin"
        | "cookieAuthorityId"
        | "cookieGeneration"
        | "coordinationRevision"
        | "schemaVersion"
        | "writeNonce"
      >
    : never;

export type RecordRead =
  | { kind: "missing" }
  | { kind: "corrupt" }
  | { kind: "valid"; record: WebSessionRecord };

/** Where the record is kept for the API origin (the device storage key; localStorage's for the page adapter). */
export const webSessionStorageKey = (origin: string) =>
  `comma.session-lifecycle.v1:${encodeURIComponent(origin)}`;

/** The Web Lock and the BroadcastChannel every context changing the origin's Cookie uses, the page adapter too. */
export const webSessionLockName = (origin: string) =>
  `comma.session-lifecycle.v1:${origin}`;
export const webSessionChannelName = (origin: string) =>
  `comma.session-lifecycle.v1:${origin}`;

/**
 * What the next core continues of this one's snapshots (device storage): its authority, generation and revision, and
 * the session its lease was for. A core that takes over (another tab's worker) goes on as the same authority, so the
 * pages' views and expectations of the session stay valid when it finds the same session.
 */
export const webSessionAuthorityKey = (origin: string) =>
  `comma.session-authority.v1:${encodeURIComponent(origin)}`;

export const webSessionAuthoritySchema = z.strictObject({
  authorityInstanceId: boundedId,
  generation: safeInteger,
  revision: safeInteger,
  sessionId: boundedId.nullable(),
});

/** Where the core notes that a guest's chat waits to be imported into the next registered account. */
export const guestImportMarkerKey = (origin: string) =>
  `comma.guestImportPending.v1:${origin}`;

export function readRecord(raw: string | null, origin: string): RecordRead {
  if (raw === null) return { kind: "missing" };
  try {
    const record = webSessionRecordSchema.parse(JSON.parse(raw));
    return record.canonicalApiOrigin === origin
      ? { kind: "valid", record }
      : { kind: "corrupt" };
  } catch {
    return { kind: "corrupt" };
  }
}

/** `next` as it may follow `previous`; throws when it may not (a bug: the write is refused). */
export function checkedRecord(
  previous: WebSessionRecord | undefined,
  value: unknown
): WebSessionRecord {
  const next = webSessionRecordSchema.parse(value);
  if (!previous) {
    if (next.kind !== "recovering")
      throw new Error("A new Web Cookie authority must begin with a recovery ticket.");
    return next;
  }
  if (next.canonicalApiOrigin !== previous.canonicalApiOrigin)
    throw new Error("Web Session coordination origin cannot change.");
  if (next.writeNonce === previous.writeNonce)
    throw new Error("Web Session coordination write nonce must change.");
  if (next.cookieAuthorityId !== previous.cookieAuthorityId) {
    if (next.kind !== "recovering" || next.ticket.expectation.kind !== "unknown_rebind")
      throw new Error(
        "A replacement Web Cookie authority must begin with unknown recovery."
      );
    if (next.coordinationRevision !== 0 || next.cookieGeneration !== 0)
      throw new Error("A replacement Web Cookie authority must reset its axes.");
    return next;
  }
  if (next.coordinationRevision !== previous.coordinationRevision + 1)
    throw new Error("Web Session coordination revision must advance exactly once.");
  if (next.cookieGeneration < previous.cookieGeneration)
    throw new Error("Web Cookie generation cannot regress.");
  const before = recordSessionId(previous);
  const after = recordSessionId(next);
  if (
    before !== undefined &&
    after !== undefined &&
    before !== after &&
    next.cookieGeneration === previous.cookieGeneration
  )
    throw new Error(
      "Web Cookie Session presence cannot change without a new generation."
    );
  return next;
}

export function settledStateOf(record: SettledRecord): SettledState {
  if (record.kind === "stable") return { kind: "stable", state: record.state };
  return {
    activeAuthAttemptId: record.activeAuthAttemptId,
    kind: "authenticating",
    operationEpoch: record.operationEpoch,
    state: record.state,
  };
}

/**
 * The session the record says the Cookie names: an id, null for none, undefined when it does not know (recovering,
 * or a product 401's marker: that commits the captured session's revocation, so it names no usable session).
 */
export function recordSessionId(record: WebSessionRecord): string | null | undefined {
  if (
    record.kind === "in_flight" &&
    record.operation.kind === "product_unauthorized_reconcile"
  )
    return undefined;
  const settled =
    record.kind === "stable" || record.kind === "authenticating"
      ? settledStateOf(record)
      : record.kind === "in_flight"
        ? record.prior
        : undefined;
  if (!settled) return undefined;
  if (settled.kind === "authenticating" || settled.state.kind === "absent") return null;
  return settled.state.sessionId;
}
