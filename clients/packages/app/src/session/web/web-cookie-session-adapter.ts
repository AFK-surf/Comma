import {
  createSessionOperationError,
  createSessionOperationErrorOrUnknown,
  createSessionProblem,
  mergeSessionSnapshot,
  sessionExpectation,
  sessionProductLease,
  type SessionAbsenceExpectation,
  type SessionAuthAttemptRef,
  type SessionLifecycleExpectation,
  type SessionLifecycleSnapshot,
  type SessionOperationErrorCodeFor,
  type SessionOperationName,
  type SessionOperationResult,
  type SessionProductLease,
  type SignedInSessionSnapshot,
  type SignedOutSessionSnapshot,
  type TerminalSessionSnapshot,
} from "@comma/session-contract";
import { z } from "zod";
import {
  coordinationSessionId,
  readWebSessionCoordinationRecord,
  settledStateFromRecord,
  webSessionCoordinationBroadcastName,
  webSessionCoordinationLockName,
  webSessionCoordinationStorageKey,
  webSessionLifecycleVersion,
  writeWebSessionCoordinationRecord,
  type WebSessionCoordinationRecord,
  type WebSessionInFlightOperation,
} from "./coordination-record";
import type {
  WebSessionBroadcastChannel,
  WebSessionCoordinationHint,
  WebSessionHostPorts,
} from "./coordination-ports";

const lockAcquireTimeoutMs = 2_000;
const remoteOperationTimeoutMs = 8_000;
const recoveryWindowMs = 20_000;
const recoveryBackoffMs = 250;
const recoveryMaxAttempts = 2;
// Background re-probes after a signed-in probe could not reach the server.
// After the last one the tab stays signed in; product requests still carry
// the expected session and surface a real 401 or 409.
const backgroundReconcileDelaysMs = [1_000, 3_000, 10_000, 30_000] as const;

const webSessionUserSchema = z.object({
  email: z.string().email(),
  id: z.string().min(1).max(256),
  name: z.string().min(1).max(512).nullable().optional(),
  status: z.string().min(1).max(64).nullable().optional(),
});

// Unknown fields are ignored so a newer backend stays compatible, but the
// Cookie transport must never receive a bearer.
const webSessionProjectionSchema = z.object({
  expires_at: z.number().int().positive(),
  session_id: z.string().min(1).max(256),
  token: z.never().optional(),
  user: webSessionUserSchema,
});

const webEmailChallengeSchema = z.object({
  challenge_id: z.string().min(1).max(256),
  code: z.string().min(1).max(32).optional(),
});

const webGoogleAttemptSchema = z.object({
  attempt_id: z.string().min(1).max(256),
  client_id: z.string().min(1).max(2_048),
  nonce: z.string().min(1).max(2_048),
  platform: z.literal("web"),
});

const webGoogleLinkChallengeSchema = z.object({
  challenge_id: z.string().min(1).max(256),
  code: z.string().min(1).max(32).optional(),
  email: z.string().email(),
  status: z.literal("otp_required"),
});

const webGoogleCompletionSchema = z.union([
  webSessionProjectionSchema,
  webGoogleLinkChallengeSchema,
]);

const signedOutResponseSchema = z.object({
  signed_out: z.literal(true),
});

const unauthorizedResponseSchema = z.object({
  error: z.literal("unauthorized"),
});

const sessionChangedResponseSchema = z.object({
  error: z.literal("session_changed"),
});

const protocolErrorResponseSchema = z
  .object({
    contract_version: z.literal(1).optional(),
    error: z.enum([
      "invalid_session_precondition",
      "session_lifecycle_version_required",
      "unsupported_session_lifecycle_version",
    ]),
  })
  .or(
    z.object({
      error: z.literal("invalid_session_precondition"),
    })
  );

type WebSessionProjection = z.output<typeof webSessionProjectionSchema>;
type WebLifecycleResponse = {
  body: unknown;
  ok: boolean;
  status: number;
};
type CoordinationRecordHeaderKey =
  | "canonicalApiOrigin"
  | "cookieAuthorityId"
  | "cookieGeneration"
  | "coordinationRevision"
  | "schemaVersion"
  | "writeNonce";
type CoordinationRecordBody<
  Record extends WebSessionCoordinationRecord = WebSessionCoordinationRecord,
> = Record extends WebSessionCoordinationRecord
  ? Omit<Record, CoordinationRecordHeaderKey>
  : never;

export type WebCookieSessionProductLease = SessionProductLease & {
  cookieAuthorityId: string;
  cookieGeneration: number;
  signal: AbortSignal;
};

export type WebEmailLoginChallenge = {
  attempt: SessionAuthAttemptRef;
  challengeId: string;
  code?: string | undefined;
};

export type WebGoogleLoginPreparation = {
  attempt: SessionAuthAttemptRef;
  clientId: string;
  nonce: string;
  providerAttemptId: string;
};

export type WebGoogleSignInValue =
  | { snapshot: SignedInSessionSnapshot; status: "signed_in" }
  | {
      attempt: SessionAuthAttemptRef;
      challengeId: string;
      code?: string | undefined;
      email: string;
      status: "otp_required";
    };

type SnapshotListener = (snapshot: SessionLifecycleSnapshot) => void;

type AdoptedCookieProjection = {
  cookieAuthorityId: string;
  cookieGeneration: number;
  coordinationRevision: number;
  sessionId: string | null | undefined;
};

type LocalAuthAttempt = {
  attempt: SessionAuthAttemptRef;
  challengeId?: string | undefined;
  kind: "email" | "google";
  operationEpoch: number;
};

class WebSessionUnsupportedError extends Error {}
class WebSessionLockTimeoutError extends Error {}
class WebSessionStorageError extends Error {}

export class WebCookieSessionAdapter {
  readonly authorityInstanceId: string;
  readonly canonicalApiOrigin: string;

  readonly baseUrl: string;
  private readonly broadcast: WebSessionBroadcastChannel;
  private readonly broadcastName: string;
  private readonly coordinationLockName: string;
  private readonly coordinationStorageKey: string;
  private readonly coordinationSenderId: string;
  private readonly listeners = new Set<SnapshotListener>();
  private readonly ports: WebSessionHostPorts;
  private adoptedCookie: AdoptedCookieProjection | undefined;
  private authAttempt: LocalAuthAttempt | undefined;
  private backgroundReconcileAttempt = 0;
  private backgroundReconcileHandle: number | undefined;
  private disposed = false;
  private operationEpoch = 0;
  private productController: AbortController | undefined;
  private snapshot: SessionLifecycleSnapshot;
  private unsubscribeBroadcast: () => void;

  constructor(input: { baseUrl: string; ports: WebSessionHostPorts }) {
    this.ports = input.ports;
    this.baseUrl = normalizeBaseUrl(input.baseUrl, input.ports.documentOrigin);
    this.canonicalApiOrigin = new URL(this.baseUrl).origin;
    this.authorityInstanceId = input.ports.randomId();
    this.coordinationSenderId = input.ports.randomId();
    this.coordinationStorageKey = webSessionCoordinationStorageKey(
      this.canonicalApiOrigin
    );
    this.coordinationLockName = webSessionCoordinationLockName(this.canonicalApiOrigin);
    this.broadcastName = webSessionCoordinationBroadcastName(this.canonicalApiOrigin);
    this.broadcast = input.ports.broadcast.open(this.broadcastName);
    this.snapshot = {
      authority: {
        authorityInstanceId: this.authorityInstanceId,
        kind: "web_cookie",
      },
      cleanup: { revocation: "idle" },
      contractVersion: 1,
      generation: 0,
      phase: "initializing",
      principal: null,
      revision: 0,
      session: null,
    };

    this.unsubscribeBroadcast = this.broadcast.subscribe((hint) => {
      this.handleCoordinationHint(hint);
    });
  }

  dispose() {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.cancelBackgroundReconcile();
    this.unsubscribeBroadcast();
    this.broadcast.close();
    this.revokeProductLease();
    this.listeners.clear();
  }

  getSnapshot(): Promise<SessionLifecycleSnapshot> {
    return Promise.resolve(this.snapshot);
  }

  getSnapshotSync(): SessionLifecycleSnapshot {
    return this.snapshot;
  }

  subscribe(listener: SnapshotListener) {
    this.listeners.add(listener);
    listener(this.snapshot);
    return () => {
      this.listeners.delete(listener);
    };
  }

  getProductLease(): WebCookieSessionProductLease | undefined {
    const lease = sessionProductLease(this.snapshot);
    const adopted = this.adoptedCookie;
    const signal = this.productController?.signal;

    if (
      !lease ||
      !adopted ||
      adopted.sessionId !== lease.sessionId ||
      !signal ||
      signal.aborted
    ) {
      return undefined;
    }

    return {
      ...lease,
      cookieAuthorityId: adopted.cookieAuthorityId,
      cookieGeneration: adopted.cookieGeneration,
      signal,
    };
  }

  async recover() {
    if (this.snapshot.phase === "initializing") {
      await this.reconcile({ reason: "startup" });
      return;
    }

    const expected = this.currentReconcileExpectation();
    if (!expected) {
      if (
        this.snapshot.phase === "indeterminate" &&
        this.adoptedCookie?.sessionId === undefined
      ) {
        const epoch = this.nextOperationEpoch();
        try {
          await this.withCoordinationLock(async () => {
            const record = this.ensureManualRecoveryRecord();
            if (record.kind === "recovering") {
              await this.runRecovery(record, epoch);
            }
          });
        } catch (error) {
          this.handleLifecycleFailure("reconcile", error, epoch);
        }
      }
      return;
    }
    await this.reconcile({ expected, reason: "manual_retry" });
  }

  async exchangeTelegramLaunch(input: { initData: string; groupId: string }) {
    const epoch = this.nextOperationEpoch();
    try {
      return await this.withCoordinationLock(async () => {
        const read = this.readRecord();
        // A signed launch is an explicit authentication intent. Persist recovery
        // before the server can replace the Cookie, including a lost response.
        const recovery = this.createUnknownRecovery(
          read.kind === "valid" ? read.record : undefined
        );
        this.authAttempt = undefined;
        this.revokeProductLease();
        this.adoptRecord(recovery);
        this.publishTransient("authenticating");

        let response: WebLifecycleResponse;
        try {
          response = await this.fetchLifecycle(
            "POST",
            "/v1/comma/auth/telegram-miniapp",
            "unknown",
            { init_data: input.initData, group_id: input.groupId }
          );
        } catch {
          this.publishIndeterminate("credential_mutation_uncertain", "authenticate");
          return "failed" as const;
        }

        if (!response.ok) {
          this.publishIndeterminate("protocol_mismatch", "authenticate");
          return response.status === 409
            ? ("account_mismatch" as const)
            : ("failed" as const);
        }
        const projection = await parseJson(response, webSessionProjectionSchema);
        if (!projection) {
          this.publishIndeterminate("protocol_mismatch", "authenticate");
          return "failed" as const;
        }
        const stable = this.writeNext(
          recovery,
          {
            kind: "stable",
            state: { kind: "present", sessionId: projection.session_id },
          },
          recovery.cookieGeneration + 1
        );
        this.adoptRecord(stable);
        this.publishSignedIn(projection);
        this.publishHint(stable);
        return "signed_in" as const;
      });
    } catch (error) {
      this.handleLifecycleFailure("reconcile", error, epoch);
      return "failed" as const;
    }
  }

  async reconcile(input: {
    expected?: SessionLifecycleExpectation;
    reason: "startup" | "focus" | "manual_retry" | "peer_mutation";
  }): Promise<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    if (input.expected && !this.localExpectationMatches(input.expected)) {
      return this.failure("reconcile", "conflict");
    }
    if (
      !input.expected &&
      (input.reason !== "startup" || this.snapshot.phase !== "initializing")
    ) {
      return this.failure("reconcile", "conflict");
    }

    // A rejected wake or peer hint must not cancel an admitted probe's completion.
    const epoch = this.nextOperationEpoch();
    try {
      return await this.withCoordinationLock(async () => {
        // A newer wake may have superseded this probe while it waited for the lock.
        if (!this.isCurrentEpoch(epoch)) {
          return this.failure("reconcile", "conflict");
        }
        const record =
          input.reason === "manual_retry"
            ? this.ensureManualRecoveryRecord()
            : this.ensureRecoverableRecord();
        if (record.kind === "recovering") {
          return this.runRecovery(record, epoch);
        }
        if (record.kind === "in_flight") {
          return this.failure("reconcile", "conflict");
        }
        return this.runProbe(record, epoch, input.expected);
      });
    } catch (error) {
      return this.handleLifecycleFailure("reconcile", error, epoch);
    }
  }

  async requestEmailLogin(input: {
    email: string;
    expected: SessionAbsenceExpectation;
  }): Promise<SessionOperationResult<WebEmailLoginChallenge, "request_email_login">> {
    const epoch = this.nextOperationEpoch();
    const attempt = this.newAuthAttempt(input.expected);

    if (!this.canStartAuthentication(input.expected)) {
      return this.failure("request_email_login", "conflict");
    }

    try {
      return await this.withCoordinationLock(async () => {
        const record = this.ensureSettledRecordForIntent();
        if (!this.canCommitAuthAttempt(record, input.expected)) {
          return this.failure("request_email_login", "conflict");
        }

        const authenticating = this.writeNext(record, {
          activeAuthAttemptId: attempt.attemptId,
          kind: "authenticating",
          operationEpoch: epoch,
          state: { kind: "absent" },
        });
        this.authAttempt = {
          attempt,
          kind: "email",
          operationEpoch: epoch,
        };
        this.adoptRecord(authenticating);
        this.publishTransient("authenticating");

        let response: WebLifecycleResponse;
        try {
          response = await this.fetchLifecycle(
            "POST",
            "/v1/comma/auth/email/login",
            "none",
            {
              email: input.email.trim(),
            }
          );
        } catch (error) {
          this.clearAuthAttemptIfCurrent(authenticating, attempt.attemptId);
          return this.failure("request_email_login", classifyNetworkFailure(error));
        }

        if (response.ok) {
          const parsed = await parseJson(response, webEmailChallengeSchema);
          if (!parsed) {
            this.clearAuthAttemptIfCurrent(authenticating, attempt.attemptId);
            return this.failure("request_email_login", "protocol_mismatch");
          }
          if (!this.isCurrentAuthAttempt(attempt, epoch)) {
            return this.failure("request_email_login", "conflict");
          }

          this.authAttempt = {
            attempt,
            challengeId: parsed.challenge_id,
            kind: "email",
            operationEpoch: epoch,
          };
          return {
            ok: true,
            value: {
              attempt,
              challengeId: parsed.challenge_id,
              ...(parsed.code ? { code: parsed.code } : {}),
            },
          };
        }

        this.clearAuthAttemptIfCurrent(authenticating, attempt.attemptId);
        return this.failure("request_email_login", classifyAuthStartResponse(response));
      });
    } catch (error) {
      return this.handleOperationFailure("request_email_login", error, epoch);
    }
  }

  async verifyEmailLogin(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Promise<SessionOperationResult<SignedInSessionSnapshot, "verify_email_login">> {
    return this.completeAuthMutation({
      attempt: input.attempt,
      body: {
        challenge_id: input.challengeId,
        code: input.code,
        ...webSessionClientMetadata(),
      },
      kind: "verify_email_login",
      path: "/v1/comma/auth/email/verify",
      schema: webSessionProjectionSchema,
      unauthorizedCode: "invalid_challenge",
      settle: (value) => ({ kind: "signed_in", projection: value }),
    });
  }

  async beginGoogleLogin(input: {
    expected: SessionAbsenceExpectation;
  }): Promise<
    SessionOperationResult<WebGoogleLoginPreparation, "sign_in_with_google">
  > {
    const epoch = this.nextOperationEpoch();
    const attempt = this.newAuthAttempt(input.expected);

    if (!this.canStartAuthentication(input.expected)) {
      return this.failure("sign_in_with_google", "conflict");
    }

    try {
      return await this.withCoordinationLock(async () => {
        const record = this.ensureSettledRecordForIntent();
        if (!this.canCommitAuthAttempt(record, input.expected)) {
          return this.failure("sign_in_with_google", "conflict");
        }

        const authenticating = this.writeNext(record, {
          activeAuthAttemptId: attempt.attemptId,
          kind: "authenticating",
          operationEpoch: epoch,
          state: { kind: "absent" },
        });
        this.authAttempt = {
          attempt,
          kind: "google",
          operationEpoch: epoch,
        };
        this.adoptRecord(authenticating);
        this.publishTransient("authenticating");

        let response: WebLifecycleResponse;
        try {
          response = await this.fetchLifecycle(
            "POST",
            "/v1/comma/auth/google/attempt",
            "none",
            { platform: "web" }
          );
        } catch (error) {
          this.clearAuthAttemptIfCurrent(authenticating, attempt.attemptId);
          return this.failure("sign_in_with_google", classifyNetworkFailure(error));
        }

        if (!response.ok) {
          this.clearAuthAttemptIfCurrent(authenticating, attempt.attemptId);
          return this.failure(
            "sign_in_with_google",
            classifyAuthStartResponse(response)
          );
        }

        const parsed = await parseJson(response, webGoogleAttemptSchema);
        if (!parsed || !this.isCurrentAuthAttempt(attempt, epoch)) {
          this.clearAuthAttemptIfCurrent(authenticating, attempt.attemptId);
          return this.failure(
            "sign_in_with_google",
            parsed ? "conflict" : "protocol_mismatch"
          );
        }

        return {
          ok: true,
          value: {
            attempt,
            clientId: parsed.client_id,
            nonce: parsed.nonce,
            providerAttemptId: parsed.attempt_id,
          },
        };
      });
    } catch (error) {
      return this.handleOperationFailure("sign_in_with_google", error, epoch);
    }
  }

  async completeGoogleLogin(input: {
    attempt: SessionAuthAttemptRef;
    credential: string;
    nonce: string;
    providerAttemptId: string;
  }): Promise<SessionOperationResult<WebGoogleSignInValue, "sign_in_with_google">> {
    return this.completeAuthMutation({
      attempt: input.attempt,
      body: {
        attempt_id: input.providerAttemptId,
        credential: input.credential,
        nonce: input.nonce,
        ...webSessionClientMetadata(),
      },
      kind: "complete_google_login",
      operation: "sign_in_with_google",
      path: "/v1/comma/auth/google",
      schema: webGoogleCompletionSchema,
      unauthorizedCode: "unknown",
      settle: (value) =>
        "status" in value
          ? { kind: "otp_required", value }
          : { kind: "signed_in", projection: value },
    });
  }

  async verifyGoogleLink(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Promise<SessionOperationResult<SignedInSessionSnapshot, "verify_google_link">> {
    return this.completeAuthMutation({
      attempt: input.attempt,
      body: {
        challenge_id: input.challengeId,
        code: input.code,
        ...webSessionClientMetadata(),
      },
      kind: "verify_google_link",
      operation: "verify_google_link",
      path: "/v1/comma/auth/google/link/verify",
      schema: webSessionProjectionSchema,
      unauthorizedCode: "invalid_challenge",
      settle: (value) => ({ kind: "signed_in", projection: value }),
    });
  }

  async cancelAuthAttempt(input: {
    attempt: SessionAuthAttemptRef;
  }): Promise<SessionOperationResult<SignedOutSessionSnapshot, "cancel_auth_attempt">> {
    const epoch = this.nextOperationEpoch();
    if (!this.isCurrentAuthAttempt(input.attempt)) {
      return this.failure("cancel_auth_attempt", "conflict");
    }

    try {
      return await this.withCoordinationLock(async () => {
        const record = this.ensureSettledRecordForIntent();
        if (
          record.kind !== "authenticating" ||
          record.activeAuthAttemptId !== input.attempt.attemptId
        ) {
          return this.failure("cancel_auth_attempt", "conflict");
        }

        const stable = this.writeNext(record, {
          kind: "stable",
          state: { kind: "absent" },
        });
        this.authAttempt = undefined;
        this.adoptRecord(stable);
        const snapshot = this.publishSignedOut("no_session");
        return { ok: true, value: snapshot };
      });
    } catch (error) {
      return this.handleOperationFailure("cancel_auth_attempt", error, epoch);
    }
  }

  async signOut(input: {
    expected: SessionLifecycleExpectation;
  }): Promise<SessionOperationResult<SignedOutSessionSnapshot, "sign_out">> {
    const epoch = this.nextOperationEpoch();

    if (
      this.snapshot.phase === "signed_out" &&
      this.localExpectationMatches(input.expected)
    ) {
      return { ok: true, value: this.snapshot };
    }
    if (
      this.snapshot.phase !== "signed_in" ||
      !this.localExpectationMatches(input.expected)
    ) {
      return this.failure("sign_out", "conflict");
    }

    const expectedSessionId = this.snapshot.session.sessionId;
    this.publishTransient("signing_out");

    try {
      return await this.withCoordinationLock(async () => {
        const record = this.ensureSettledRecordForIntent();
        if (!this.recordMatchesCurrentLease(record, expectedSessionId)) {
          this.publishIndeterminate("protocol_mismatch", "sign_out");
          return this.failure("sign_out", "conflict");
        }

        const marker = this.writeInFlight(record, epoch, {
          expectedSessionId,
          kind: "sign_out",
        });

        let response: WebLifecycleResponse;
        try {
          response = await this.fetchLifecycle(
            "POST",
            "/v1/comma/auth/logout",
            expectedSessionId,
            {}
          );
        } catch {
          this.publishIndeterminate("credential_mutation_uncertain", "sign_out");
          return this.failure("sign_out", "credential_mutation_uncertain");
        }

        if (response.ok) {
          const parsed = await parseJson(response, signedOutResponseSchema);
          if (!parsed) {
            this.restoreAfterResponse(marker);
            this.publishIndeterminate("protocol_mismatch", "sign_out");
            return this.failure("sign_out", "protocol_mismatch");
          }
          return this.commitSignedOut(marker, epoch, "user_signed_out");
        }

        if (
          response.status === 401 &&
          (await parseJson(response, unauthorizedResponseSchema))
        ) {
          return this.commitSignedOut(marker, epoch, "unauthorized");
        }

        this.restoreAfterResponse(marker);
        this.publishIndeterminate(
          response.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch",
          "sign_out"
        );
        return this.failure(
          "sign_out",
          response.status >= 500 ? "network_unavailable" : "protocol_mismatch"
        );
      });
    } catch (error) {
      return this.handleOperationFailure("sign_out", error, epoch);
    }
  }

  reportProductUnauthorized(lease: WebCookieSessionProductLease) {
    if (!this.isCurrentProductLease(lease)) {
      return;
    }
    const epoch = this.nextOperationEpoch();
    // A product 401 is terminal for this tab's captured lease. Close the
    // local gate before contending on the cross-tab Cookie authority lock so
    // queued or subsequent product work cannot reuse the rejected lease.
    this.revokeProductLease();
    void this.withCoordinationLock(async () => {
      const record = this.ensureSettledRecordForIntent();
      if (
        !this.isCurrentEpoch(epoch) ||
        !this.isCurrentProductLeaseIdentity(lease) ||
        !this.recordMatchesLease(record, lease)
      ) {
        return;
      }

      const marker = this.writeInFlight(
        record,
        epoch,
        {
          expectedSessionId: lease.sessionId,
          kind: "product_unauthorized_reconcile",
        },
        record.cookieGeneration + 1
      );
      this.publishHint(marker);
      this.publishTransient("invalidating");

      let response: WebLifecycleResponse;
      try {
        response = await this.fetchLifecycle(
          "GET",
          "/v1/comma/auth/session",
          lease.sessionId
        );
      } catch {
        const recovering = this.writeExactSessionRecovery(marker, lease.sessionId);
        this.adoptRecord(recovering);
        this.publishIndeterminate("credential_mutation_uncertain", "invalidate");
        this.publishHint(recovering);
        return;
      }

      if (response.ok) {
        const projection = await parseJson(response, webSessionProjectionSchema);
        if (projection?.session_id === lease.sessionId) {
          const stable = this.writeNext(marker, {
            kind: "stable",
            state: { kind: "present", sessionId: lease.sessionId },
          });
          this.adoptRecord(stable);
          this.publishSignedIn(projection);
          this.publishHint(stable);
          return;
        }
      } else if (
        response.status === 401 &&
        (await parseJson(response, unauthorizedResponseSchema))
      ) {
        this.commitSignedOut(marker, epoch, "unauthorized");
        return;
      } else if (
        response.status === 409 &&
        (await parseJson(response, sessionChangedResponseSchema))
      ) {
        await this.rebindToCurrentCookie(this.restoreAfterResponse(marker), epoch);
        return;
      }

      if (response.status >= 500) {
        const recovering = this.writeExactSessionRecovery(marker, lease.sessionId);
        this.adoptRecord(recovering);
        this.publishIndeterminate("session_probe_unavailable", "invalidate");
        this.publishHint(recovering);
        return;
      }

      this.restoreAfterResponse(marker);
      this.publishIndeterminate("protocol_mismatch", "invalidate");
    }).catch((error: unknown) => {
      this.handleLifecycleFailure("reconcile", error, epoch);
    });
  }

  reportProductSessionChanged(lease: WebCookieSessionProductLease) {
    if (!this.isCurrentProductLease(lease) || this.snapshot.phase !== "signed_in") {
      return;
    }
    void this.reconcile({
      expected: sessionExpectation(this.snapshot),
      reason: "peer_mutation",
    });
  }

  private async completeAuthMutation<
    Schema extends z.ZodType,
    Operation extends
      | "sign_in_with_google"
      | "verify_email_login"
      | "verify_google_link",
    Value,
  >(input: {
    attempt: SessionAuthAttemptRef;
    body: Record<string, string>;
    kind: "complete_google_login" | "verify_email_login" | "verify_google_link";
    operation?: Operation;
    path: string;
    schema: Schema;
    unauthorizedCode: SessionOperationErrorCodeFor<Operation>;
    settle: (value: z.output<Schema>) =>
      | { kind: "signed_in"; projection: WebSessionProjection }
      | {
          kind: "otp_required";
          value: z.output<typeof webGoogleLinkChallengeSchema>;
        };
  }): Promise<SessionOperationResult<Value, Operation>> {
    const operation =
      input.operation ??
      (input.kind === "verify_email_login"
        ? "verify_email_login"
        : "verify_google_link");
    const epoch = this.nextOperationEpoch();

    if (!this.isCurrentAuthAttempt(input.attempt)) {
      return this.failure(operation, "conflict") as SessionOperationResult<
        Value,
        Operation
      >;
    }

    try {
      return await this.withCoordinationLock(async () => {
        const record = this.ensureSettledRecordForIntent();
        if (
          record.kind !== "authenticating" ||
          record.activeAuthAttemptId !== input.attempt.attemptId ||
          !this.isCurrentAuthAttempt(input.attempt)
        ) {
          return this.failure(operation, "conflict") as SessionOperationResult<
            Value,
            Operation
          >;
        }

        const marker = this.writeInFlight(record, epoch, {
          authAttemptId: input.attempt.attemptId,
          expectedSessionId: "none",
          kind: input.kind,
        });

        let response: WebLifecycleResponse;
        try {
          response = await this.fetchLifecycle("POST", input.path, "none", input.body);
        } catch {
          this.publishIndeterminate("credential_mutation_uncertain", "authenticate");
          return this.failure(
            operation,
            "credential_mutation_uncertain"
          ) as SessionOperationResult<Value, Operation>;
        }

        if (response.ok) {
          const parsed = await parseJson(response, input.schema);
          if (!parsed) {
            this.restoreAfterResponse(marker);
            this.publishIndeterminate("protocol_mismatch", "authenticate");
            return this.failure(
              operation,
              "protocol_mismatch"
            ) as SessionOperationResult<Value, Operation>;
          }

          const settled = input.settle(parsed);
          if (settled.kind === "otp_required") {
            const restored = this.restoreAfterResponse(marker);
            if (!this.isCurrentAuthAttempt(input.attempt)) {
              return this.failure(operation, "conflict") as SessionOperationResult<
                Value,
                Operation
              >;
            }
            const refreshedAttempt = this.writeNext(restored, {
              activeAuthAttemptId: input.attempt.attemptId,
              kind: "authenticating",
              operationEpoch: epoch,
              state: { kind: "absent" },
            });
            this.authAttempt = {
              attempt: input.attempt,
              challengeId: settled.value.challenge_id,
              kind: "google",
              operationEpoch: epoch,
            };
            this.adoptRecord(refreshedAttempt);
            return {
              ok: true,
              value: {
                attempt: input.attempt,
                challengeId: settled.value.challenge_id,
                ...(settled.value.code ? { code: settled.value.code } : {}),
                email: settled.value.email,
                status: "otp_required",
              } as Value,
            };
          }

          const stable = this.writeNext(
            marker,
            {
              kind: "stable",
              state: {
                kind: "present",
                sessionId: settled.projection.session_id,
              },
            },
            marker.cookieGeneration + 1
          );
          this.authAttempt = undefined;
          this.adoptRecord(stable);
          const snapshot = this.publishSignedIn(settled.projection);
          this.publishHint(stable);

          const value =
            operation === "sign_in_with_google"
              ? ({ snapshot, status: "signed_in" } as Value)
              : (snapshot as Value);
          return { ok: true, value };
        }

        if (response.status === 401) {
          this.restoreAfterResponse(marker);
          return this.failure(
            operation,
            input.unauthorizedCode
          ) as SessionOperationResult<Value, Operation>;
        }

        if (
          response.status === 409 &&
          (await parseJson(response, sessionChangedResponseSchema))
        ) {
          this.restoreAfterResponse(marker);
          return this.failure(operation, "conflict") as SessionOperationResult<
            Value,
            Operation
          >;
        }

        this.restoreAfterResponse(marker);
        return this.failure(
          operation,
          response.status === 403
            ? "account_disabled"
            : response.status === 429
              ? "rate_limited"
              : response.status >= 500
                ? "provider_unavailable"
                : "unknown"
        ) as SessionOperationResult<Value, Operation>;
      });
    } catch (error) {
      return this.handleOperationFailure(
        operation,
        error,
        epoch
      ) as SessionOperationResult<Value, Operation>;
    }
  }

  private async runProbe(
    record: Extract<
      WebSessionCoordinationRecord,
      { kind: "authenticating" | "stable" }
    >,
    epoch: number,
    callerExpected: SessionLifecycleExpectation | undefined
  ): Promise<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    if (
      this.snapshot.phase === "authenticating" ||
      this.snapshot.phase === "signing_out"
    ) {
      return this.failure("reconcile", "conflict");
    }

    const expectedSessionId = coordinationSessionId(record);
    if (expectedSessionId === undefined) {
      return this.failure("reconcile", "protocol_mismatch");
    }
    const expectedHeader = expectedSessionId ?? "none";

    if (
      callerExpected &&
      !this.cookieRecordCanReadmitReconcile(record, callerExpected)
    ) {
      return this.failure("reconcile", "conflict");
    }

    // The current lease stays usable while the probe runs: every product
    // request carries the expected session, so the server rejects it with
    // 409 if another tab moved the Cookie.
    const adoptionBeforeProbe = this.adoptedCookie;
    const marker = this.writeInFlight(record, epoch, {
      expectedSessionId: expectedHeader,
      kind: "reconcile",
    });

    let response: WebLifecycleResponse;
    try {
      response = await this.fetchLifecycle(
        "GET",
        "/v1/comma/auth/session",
        expectedHeader
      );
    } catch {
      this.restoreAfterResponse(marker);
      if (
        this.isCurrentEpoch(epoch) &&
        !this.keepSignedInThroughProbeFailure(epoch, adoptionBeforeProbe)
      ) {
        this.publishIndeterminate("session_probe_unavailable", "reconcile");
      }
      return this.failure("reconcile", "network_unavailable");
    }

    if (!this.isCurrentEpoch(epoch)) {
      this.restoreAfterResponse(marker);
      return this.failure("reconcile", "conflict");
    }

    if (response.ok) {
      const projection = await parseJson(response, webSessionProjectionSchema);
      if (
        !projection ||
        expectedSessionId === null ||
        projection.session_id !== expectedSessionId
      ) {
        this.restoreAfterResponse(marker);
        if (this.isCurrentEpoch(epoch)) {
          this.publishIndeterminate("protocol_mismatch", "reconcile");
        }
        return this.failure("reconcile", "protocol_mismatch");
      }

      const stable = this.writeNext(marker, {
        kind: "stable",
        state: { kind: "present", sessionId: projection.session_id },
      });
      this.adoptRecord(stable);
      const snapshot = this.publishSignedIn(projection);
      return { ok: true, value: snapshot };
    }

    if (
      response.status === 401 &&
      (await parseJson(response, unauthorizedResponseSchema))
    ) {
      const nextGeneration =
        expectedSessionId === null
          ? marker.cookieGeneration
          : marker.cookieGeneration + 1;
      const stable = this.writeNext(
        marker,
        {
          kind: "stable",
          state: { kind: "absent" },
        },
        nextGeneration
      );
      this.adoptRecord(stable);
      const snapshot = this.publishSignedOut(
        expectedSessionId === null ? "no_session" : "unauthorized"
      );
      if (nextGeneration !== marker.cookieGeneration) {
        this.publishHint(stable);
      }
      return { ok: true, value: snapshot };
    }

    if (
      response.status === 409 &&
      (await parseJson(response, sessionChangedResponseSchema))
    ) {
      const restored = this.restoreAfterResponse(marker);
      if (!this.isCurrentEpoch(epoch)) {
        return this.failure("reconcile", "conflict");
      }
      return this.rebindToCurrentCookie(restored, epoch);
    }

    if (
      response.status === 400 ||
      response.status === 428 ||
      (await parseJson(response, protocolErrorResponseSchema))
    ) {
      this.restoreAfterResponse(marker);
      if (this.isCurrentEpoch(epoch)) {
        this.publishIndeterminate("protocol_mismatch", "reconcile");
      }
      return this.failure("reconcile", "protocol_mismatch");
    }

    this.restoreAfterResponse(marker);
    if (
      this.isCurrentEpoch(epoch) &&
      !this.keepSignedInThroughProbeFailure(epoch, adoptionBeforeProbe)
    ) {
      this.publishIndeterminate("session_probe_unavailable", "reconcile");
    }
    return this.failure("reconcile", "session_probe_unavailable");
  }

  // A signed-in tab that still holds a live lease keeps its view when a probe
  // cannot reach the server, and retries in the background instead.
  private keepSignedInThroughProbeFailure(
    epoch: number,
    adoptionBeforeProbe: AdoptedCookieProjection | undefined
  ) {
    if (
      !this.isCurrentEpoch(epoch) ||
      this.snapshot.phase !== "signed_in" ||
      !adoptionBeforeProbe
    ) {
      return false;
    }
    const adoptionAfterProbe = this.adoptedCookie;
    this.adoptedCookie = adoptionBeforeProbe;
    if (!this.getProductLease()) {
      this.adoptedCookie = adoptionAfterProbe;
      return false;
    }
    this.scheduleBackgroundReconcile();
    return true;
  }

  private scheduleBackgroundReconcile() {
    if (this.backgroundReconcileHandle !== undefined) {
      return;
    }
    const delay = backgroundReconcileDelaysMs[this.backgroundReconcileAttempt];
    if (delay === undefined) {
      return;
    }
    this.backgroundReconcileAttempt += 1;
    this.backgroundReconcileHandle = this.ports.schedule(() => {
      this.backgroundReconcileHandle = undefined;
      if (this.disposed || this.snapshot.phase !== "signed_in") {
        return;
      }
      void this.reconcile({
        expected: sessionExpectation(this.snapshot),
        reason: "peer_mutation",
      });
    }, delay);
  }

  private cancelBackgroundReconcile() {
    if (this.backgroundReconcileHandle !== undefined) {
      this.ports.unschedule(this.backgroundReconcileHandle);
      this.backgroundReconcileHandle = undefined;
    }
    this.backgroundReconcileAttempt = 0;
  }

  private async runRecovery(
    initialRecord: Extract<WebSessionCoordinationRecord, { kind: "recovering" }>,
    epoch: number
  ): Promise<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    let record = initialRecord;
    const now = this.ports.now();
    if (
      record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
      now >= record.ticket.deadlineAtEpochMs ||
      record.ticket.progress.phase === "exhausted"
    ) {
      if (this.isCurrentEpoch(epoch)) {
        this.adoptRecord(record);
        this.publishIndeterminate("session_probe_unavailable", "reconcile");
      }
      return this.failure("reconcile", "session_probe_unavailable");
    }

    if (
      record.ticket.progress.phase === "backoff" &&
      now < record.ticket.progress.nextAttemptNotBeforeEpochMs
    ) {
      if (this.isCurrentEpoch(epoch)) {
        this.adoptRecord(record);
        this.publishIndeterminate("session_probe_unavailable", "reconcile");
      }
      return this.failure("reconcile", "session_probe_unavailable");
    }

    const ownerNonce = this.ports.randomId();
    record = this.writeNext(record, {
      kind: "recovering",
      ticket: {
        ...record.ticket,
        attemptsStarted: record.ticket.attemptsStarted + 1,
        progress: {
          ownerNonce,
          phase: "in_flight",
          startedAtEpochMs: now,
        },
      },
    });
    this.adoptRecord(record);

    const expected =
      record.ticket.expectation.kind === "unknown_rebind"
        ? "unknown"
        : record.ticket.expectation.sessionId;

    let response: WebLifecycleResponse;
    try {
      response = await this.fetchLifecycle("GET", "/v1/comma/auth/session", expected);
    } catch {
      const failed = this.settleRecoveryFailure(record, "network_unavailable");
      this.adoptRecord(failed);
      if (this.isCurrentEpoch(epoch)) {
        this.publishIndeterminate("session_probe_unavailable", "reconcile");
      }
      return this.failure("reconcile", "network_unavailable");
    }

    if (response.ok) {
      const projection = await parseJson(response, webSessionProjectionSchema);
      if (
        !projection ||
        (record.ticket.expectation.kind === "exact_session" &&
          projection.session_id !== record.ticket.expectation.sessionId)
      ) {
        const failed = this.settleRecoveryFailure(record, "protocol_mismatch");
        this.adoptRecord(failed);
        if (this.isCurrentEpoch(epoch)) {
          this.publishIndeterminate("protocol_mismatch", "reconcile");
        }
        return this.failure("reconcile", "protocol_mismatch");
      }

      const nextGeneration =
        record.ticket.expectation.kind === "unknown_rebind"
          ? record.cookieGeneration + 1
          : record.cookieGeneration;
      const stable = this.writeNext(
        record,
        {
          kind: "stable",
          state: { kind: "present", sessionId: projection.session_id },
        },
        nextGeneration
      );
      this.adoptRecord(stable);
      const snapshot = this.publishSignedIn(projection);
      this.publishHint(stable);
      return { ok: true, value: snapshot };
    }

    if (
      response.status === 401 &&
      (await parseJson(response, unauthorizedResponseSchema))
    ) {
      const nextGeneration =
        record.ticket.expectation.kind === "unknown_rebind"
          ? record.cookieGeneration + 1
          : record.cookieGeneration;
      const stable = this.writeNext(
        record,
        {
          kind: "stable",
          state: { kind: "absent" },
        },
        nextGeneration
      );
      this.adoptRecord(stable);
      const snapshot = this.publishSignedOut("no_session");
      this.publishHint(stable);
      return { ok: true, value: snapshot };
    }

    if (
      response.status === 409 &&
      record.ticket.expectation.kind === "exact_session" &&
      (await parseJson(response, sessionChangedResponseSchema))
    ) {
      return this.rebindToCurrentCookie(record, epoch);
    }

    const failed = this.settleRecoveryFailure(
      record,
      response.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch"
    );
    this.adoptRecord(failed);
    if (this.isCurrentEpoch(epoch)) {
      this.publishIndeterminate(
        response.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch",
        "reconcile"
      );
    }
    return this.failure(
      "reconcile",
      response.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch"
    );
  }

  // A 409 means the shared Cookie now names another session: another tab
  // signed in, signed out, or switched accounts. Adopt whatever the Cookie
  // holds. The caller must hold the coordination lock.
  private rebindToCurrentCookie(
    previous: WebSessionCoordinationRecord,
    epoch: number
  ): Promise<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    const recovery = this.createUnknownRecovery(previous);
    this.adoptRecord(recovery);
    return this.runRecovery(recovery, epoch);
  }

  private ensureRecoverableRecord(): WebSessionCoordinationRecord {
    const read = this.readRecord();
    if (read.kind === "missing" || read.kind === "corrupt") {
      return this.createUnknownRecovery(undefined);
    }

    const record = read.record;
    if (record.kind === "in_flight") {
      return this.createUnknownRecovery(record);
    }

    if (record.kind === "recovering" && record.ticket.progress.phase === "in_flight") {
      const exhausted =
        record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
        this.ports.now() >= record.ticket.deadlineAtEpochMs;
      return this.writeNext(record, {
        kind: "recovering",
        ticket: {
          ...record.ticket,
          progress: exhausted
            ? {
                phase: "exhausted",
                problem: "session_probe_unavailable",
              }
            : { phase: "ready" },
        },
      });
    }

    return record;
  }

  private ensureManualRecoveryRecord(): WebSessionCoordinationRecord {
    const record = this.ensureRecoverableRecord();
    if (record.kind !== "recovering") {
      return record;
    }

    const now = this.ports.now();
    const exhausted =
      record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
      now >= record.ticket.deadlineAtEpochMs ||
      record.ticket.progress.phase === "exhausted";
    if (exhausted) {
      return this.writeNext(record, {
        kind: "recovering",
        ticket: {
          attemptsStarted: 0,
          deadlineAtEpochMs: now + recoveryWindowMs,
          expectation: record.ticket.expectation,
          maxAttempts: recoveryMaxAttempts,
          progress: { phase: "ready" },
          ticketId: this.ports.randomId(),
        },
      });
    }

    if (record.ticket.progress.phase === "backoff") {
      return this.writeNext(record, {
        kind: "recovering",
        ticket: {
          ...record.ticket,
          progress: { phase: "ready" },
        },
      });
    }

    return record;
  }

  private ensureSettledRecordForIntent(): Extract<
    WebSessionCoordinationRecord,
    { kind: "authenticating" | "stable" }
  > {
    const record = this.ensureRecoverableRecord();
    if (record.kind !== "authenticating" && record.kind !== "stable") {
      throw new WebSessionStorageError(
        "Web Cookie authority is awaiting bounded recovery."
      );
    }
    return record;
  }

  private createUnknownRecovery(
    previous: WebSessionCoordinationRecord | undefined
  ): Extract<WebSessionCoordinationRecord, { kind: "recovering" }> {
    const now = this.ports.now();
    const record: WebSessionCoordinationRecord = {
      canonicalApiOrigin: this.canonicalApiOrigin,
      cookieAuthorityId: this.ports.randomId(),
      cookieGeneration: 0,
      coordinationRevision: 0,
      kind: "recovering",
      schemaVersion: 1,
      ticket: {
        attemptsStarted: 0,
        deadlineAtEpochMs: now + recoveryWindowMs,
        expectation: { kind: "unknown_rebind" },
        maxAttempts: recoveryMaxAttempts,
        progress: { phase: "ready" },
        ticketId: this.ports.randomId(),
      },
      writeNonce: this.ports.randomId(),
    };
    return this.persist(previous, record) as Extract<
      WebSessionCoordinationRecord,
      { kind: "recovering" }
    >;
  }

  private writeExactSessionRecovery(
    previous: WebSessionCoordinationRecord,
    sessionId: string
  ): Extract<WebSessionCoordinationRecord, { kind: "recovering" }> {
    const now = this.ports.now();
    return this.writeNext(previous, {
      kind: "recovering",
      ticket: {
        attemptsStarted: 0,
        deadlineAtEpochMs: now + recoveryWindowMs,
        expectation: { kind: "exact_session", sessionId },
        maxAttempts: recoveryMaxAttempts,
        progress: { phase: "ready" },
        ticketId: this.ports.randomId(),
      },
    });
  }

  private settleRecoveryFailure(
    record: Extract<WebSessionCoordinationRecord, { kind: "recovering" }>,
    problem: "network_unavailable" | "protocol_mismatch" | "session_probe_unavailable"
  ) {
    const exhausted =
      record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
      this.ports.now() >= record.ticket.deadlineAtEpochMs ||
      problem === "protocol_mismatch";
    return this.writeNext(record, {
      kind: "recovering",
      ticket: {
        ...record.ticket,
        progress: exhausted
          ? { phase: "exhausted", problem }
          : {
              nextAttemptNotBeforeEpochMs: this.ports.now() + recoveryBackoffMs,
              phase: "backoff",
              problem,
            },
      },
    });
  }

  private clearAuthAttemptIfCurrent(
    previous: Extract<WebSessionCoordinationRecord, { kind: "authenticating" }>,
    attemptId: string
  ) {
    const read = this.readRecord();
    if (
      read.kind !== "valid" ||
      read.record.kind !== "authenticating" ||
      read.record.cookieAuthorityId !== previous.cookieAuthorityId ||
      read.record.activeAuthAttemptId !== attemptId
    ) {
      return;
    }

    const stable = this.writeNext(read.record, {
      kind: "stable",
      state: { kind: "absent" },
    });
    if (this.authAttempt?.attempt.attemptId === attemptId) {
      this.authAttempt = undefined;
      this.adoptRecord(stable);
      this.publishSignedOut("no_session");
    }
  }

  private restoreAfterResponse(
    marker: Extract<WebSessionCoordinationRecord, { kind: "in_flight" }>
  ) {
    const restored = this.writeNext(marker, marker.prior);
    this.adoptRecord(restored);
    return restored;
  }

  private commitSignedOut(
    marker: Extract<WebSessionCoordinationRecord, { kind: "in_flight" }>,
    epoch: number,
    reason: "unauthorized" | "user_signed_out"
  ): SessionOperationResult<SignedOutSessionSnapshot, "sign_out"> {
    const nextGeneration =
      marker.operation.kind === "sign_out"
        ? marker.cookieGeneration + 1
        : marker.cookieGeneration;
    const stable = this.writeNext(
      marker,
      {
        kind: "stable",
        state: { kind: "absent" },
      },
      nextGeneration
    );
    this.authAttempt = undefined;
    this.adoptRecord(stable);
    const snapshot = this.publishSignedOut(reason);
    this.publishHint(stable);
    return { ok: true, value: snapshot };
  }

  private writeInFlight(
    previous: Extract<
      WebSessionCoordinationRecord,
      { kind: "authenticating" | "stable" }
    >,
    epoch: number,
    operation: WebSessionInFlightOperation,
    cookieGeneration = previous.cookieGeneration
  ): Extract<WebSessionCoordinationRecord, { kind: "in_flight" }> {
    const now = this.ports.now();
    return this.writeNext(
      previous,
      {
        kind: "in_flight",
        operation,
        owner: {
          deadlineAtEpochMs: now + remoteOperationTimeoutMs,
          nonce: this.ports.randomId(),
          operationEpoch: epoch,
          startedAtEpochMs: now,
        },
        prior: settledStateFromRecord(previous),
      },
      cookieGeneration
    );
  }

  private writeNext<Body extends CoordinationRecordBody>(
    previous: WebSessionCoordinationRecord,
    body: Body,
    cookieGeneration = previous.cookieGeneration
  ): Extract<WebSessionCoordinationRecord, { kind: Body["kind"] }> {
    const next = {
      canonicalApiOrigin: previous.canonicalApiOrigin,
      cookieAuthorityId: previous.cookieAuthorityId,
      cookieGeneration,
      coordinationRevision: previous.coordinationRevision + 1,
      schemaVersion: 1 as const,
      writeNonce: this.ports.randomId(),
      ...body,
    };
    return this.persist(previous, next) as Extract<
      WebSessionCoordinationRecord,
      { kind: Body["kind"] }
    >;
  }

  private persist(previous: WebSessionCoordinationRecord | undefined, next: unknown) {
    try {
      return writeWebSessionCoordinationRecord(
        this.ports.storage,
        this.coordinationStorageKey,
        previous,
        next
      );
    } catch (error) {
      throw new WebSessionStorageError(
        error instanceof Error ? error.message : String(error)
      );
    }
  }

  private readRecord() {
    try {
      return readWebSessionCoordinationRecord(
        this.ports.storage,
        this.coordinationStorageKey,
        this.canonicalApiOrigin
      );
    } catch (error) {
      throw new WebSessionStorageError(
        error instanceof Error ? error.message : String(error)
      );
    }
  }

  private async withCoordinationLock<T>(work: () => Promise<T>): Promise<T> {
    const locks = this.ports.locks;
    if (!locks) {
      throw new WebSessionUnsupportedError(
        "Web Locks is required for the Cookie Session authority."
      );
    }

    const controller = new AbortController();
    const timeout = this.ports.schedule(() => {
      controller.abort(new WebSessionLockTimeoutError("Web Session lock timed out."));
    }, lockAcquireTimeoutMs);

    let acquired = false;
    try {
      return await locks.request(
        this.coordinationLockName,
        controller.signal,
        async () => {
          acquired = true;
          this.ports.unschedule(timeout);
          return work();
        }
      );
    } catch (error) {
      if (controller.signal.aborted) {
        throw new WebSessionLockTimeoutError("Web Session lock timed out.");
      }
      throw error;
    } finally {
      if (!acquired) {
        this.ports.unschedule(timeout);
      }
    }
  }

  private async fetchLifecycle(
    method: "GET" | "POST",
    path: string,
    expectedSessionId: string,
    body?: Record<string, string>
  ) {
    const controller = new AbortController();
    const timeout = this.ports.schedule(() => {
      controller.abort();
    }, remoteOperationTimeoutMs);

    const headers: Record<string, string> = {
      accept: "application/json",
      "x-comma-expected-auth-session-id": expectedSessionId,
      "x-comma-session-lifecycle-version": webSessionLifecycleVersion,
      "x-comma-session-transport": "cookie",
    };
    if (body) {
      headers["content-type"] = "application/json";
    }

    try {
      const response = await this.ports.fetch(joinUrl(this.baseUrl, path), {
        ...(body ? { body: JSON.stringify(body) } : {}),
        credentials: "include",
        headers,
        keepalive: false,
        method,
        signal: controller.signal,
      });
      let responseBody: unknown;
      try {
        responseBody = await response.json();
      } catch (error) {
        if (controller.signal.aborted) {
          throw error;
        }
      }
      return {
        body: responseBody,
        ok: response.ok,
        status: response.status,
      };
    } finally {
      this.ports.unschedule(timeout);
    }
  }

  private publishSignedIn(projection: WebSessionProjection): SignedInSessionSnapshot {
    const currentLease = this.getProductLease();
    if (!currentLease || currentLease.sessionId !== projection.session_id) {
      this.revokeProductLease();
      this.productController = new AbortController();
    }

    const next = this.publish({
      phase: "signed_in",
      principal: {
        ...(projection.user.name ? { displayName: projection.user.name } : {}),
        email: projection.user.email,
        userId: projection.user.id,
      },
      session: {
        audience: this.canonicalApiOrigin,
        expiresAtEpochSeconds: projection.expires_at,
        sessionId: projection.session_id,
      },
    });
    if (next.phase !== "signed_in") {
      throw new Error("Expected a signed-in Web Session snapshot.");
    }
    return next;
  }

  private publishSignedOut(
    reason: "no_session" | "unauthorized" | "user_signed_out"
  ): SignedOutSessionSnapshot {
    this.revokeProductLease();
    const next = this.publish({
      phase: "signed_out",
      principal: null,
      reason,
      session: null,
    });
    if (next.phase !== "signed_out") {
      throw new Error("Expected a signed-out Web Session snapshot.");
    }
    return next;
  }

  private publishTransient(phase: "authenticating" | "invalidating" | "signing_out") {
    if (phase === "invalidating" || phase === "signing_out") {
      this.revokeProductLease();
    }
    return this.publish({
      phase,
      principal: null,
      session: null,
    });
  }

  private publishIndeterminate(
    code:
      | "credential_mutation_uncertain"
      | "credential_store_unavailable"
      | "protocol_mismatch"
      | "session_probe_unavailable",
    operation: "authenticate" | "initialize" | "invalidate" | "reconcile" | "sign_out"
  ) {
    this.revokeProductLease();
    return this.publish({
      phase: "indeterminate",
      principal: null,
      problem: createSessionProblem(code, operation),
      session: null,
    });
  }

  private publish(
    body:
      | Omit<
          Extract<SessionLifecycleSnapshot, { phase: "signed_in" }>,
          "authority" | "cleanup" | "contractVersion" | "generation" | "revision"
        >
      | Omit<
          Extract<SessionLifecycleSnapshot, { phase: "signed_out" }>,
          "authority" | "cleanup" | "contractVersion" | "generation" | "revision"
        >
      | Omit<
          Extract<
            SessionLifecycleSnapshot,
            {
              phase: "authenticating" | "initializing" | "invalidating" | "signing_out";
            }
          >,
          "authority" | "cleanup" | "contractVersion" | "generation" | "revision"
        >
      | Omit<
          Extract<SessionLifecycleSnapshot, { phase: "indeterminate" }>,
          "authority" | "cleanup" | "contractVersion" | "generation" | "revision"
        >
  ) {
    const currentLease = sessionProductLease(this.snapshot);
    const nextHasLease = body.phase === "signed_in";
    const leaseChanges =
      Boolean(currentLease) !== nextHasLease ||
      (currentLease !== undefined &&
        nextHasLease &&
        currentLease.sessionId !== body.session.sessionId);
    const incoming = {
      authority: this.snapshot.authority,
      cleanup: { revocation: "idle" as const },
      contractVersion: 1 as const,
      generation: this.snapshot.generation + (leaseChanges ? 1 : 0),
      revision: this.snapshot.revision + 1,
      ...body,
    } as SessionLifecycleSnapshot;
    const merged = mergeSessionSnapshot(this.snapshot, incoming);
    if (!merged.accepted) {
      throw new Error(`Rejected local Web Session transition: ${merged.reason}`);
    }
    this.cancelBackgroundReconcile();
    this.snapshot = merged.snapshot;
    for (const listener of this.listeners) {
      listener(this.snapshot);
    }
    return this.snapshot;
  }

  private revokeProductLease() {
    this.productController?.abort();
    this.productController = undefined;
  }

  private adoptRecord(record: WebSessionCoordinationRecord) {
    this.adoptedCookie = {
      cookieAuthorityId: record.cookieAuthorityId,
      cookieGeneration: record.cookieGeneration,
      coordinationRevision: record.coordinationRevision,
      sessionId: coordinationSessionId(record),
    };
  }

  private publishHint(record: WebSessionCoordinationRecord) {
    const hint: WebSessionCoordinationHint = {
      canonicalApiOrigin: this.canonicalApiOrigin,
      cookieAuthorityId: record.cookieAuthorityId,
      cookieGeneration: record.cookieGeneration,
      coordinationRevision: record.coordinationRevision,
      kind: "session_maybe_changed",
      schemaVersion: 1,
      senderId: this.coordinationSenderId,
    };
    this.broadcast.publish(hint);
  }

  private handleCoordinationHint(value: unknown) {
    if (
      this.disposed ||
      typeof value !== "object" ||
      value === null ||
      !("kind" in value) ||
      value.kind !== "session_maybe_changed" ||
      !("schemaVersion" in value) ||
      value.schemaVersion !== 1 ||
      !("canonicalApiOrigin" in value) ||
      value.canonicalApiOrigin !== this.canonicalApiOrigin ||
      !("senderId" in value) ||
      value.senderId === this.coordinationSenderId
    ) {
      return;
    }

    const expected =
      this.snapshot.phase === "signed_in" || this.snapshot.phase === "signed_out"
        ? sessionExpectation(this.snapshot)
        : undefined;
    let read: ReturnType<typeof readWebSessionCoordinationRecord>;
    try {
      read = this.readRecord();
    } catch {
      this.publishIndeterminate("credential_store_unavailable", "reconcile");
      return;
    }
    if (read.kind !== "valid") {
      return;
    }
    const record = read.record;
    const adopted = this.adoptedCookie;
    const newerAuthority =
      !adopted ||
      record.cookieAuthorityId !== adopted.cookieAuthorityId ||
      record.cookieGeneration > adopted.cookieGeneration;
    if (newerAuthority && record.kind === "stable" && record.state.kind === "absent") {
      this.adoptRecord(record);
      this.publishSignedOut("unauthorized");
      return;
    }

    void this.reconcile({
      ...(expected ? { expected } : {}),
      reason: "peer_mutation",
    });
  }

  private localExpectationMatches(expected: SessionLifecycleExpectation) {
    if (
      expected.authorityInstanceId !== this.authorityInstanceId ||
      expected.generation !== this.snapshot.generation
    ) {
      return false;
    }
    if (this.snapshot.phase === "signed_out") {
      return expected.expectedSessionId === null;
    }
    if (this.snapshot.phase === "signed_in") {
      return (
        expected.expectedSessionId === this.snapshot.session.sessionId &&
        "expectedAudience" in expected &&
        expected.expectedAudience === this.snapshot.session.audience
      );
    }
    if (this.snapshot.phase === "indeterminate" && this.adoptedCookie) {
      const adoptedSessionId = this.adoptedCookie.sessionId;
      if (adoptedSessionId === undefined) {
        return false;
      }
      if (adoptedSessionId === null) {
        return expected.expectedSessionId === null;
      }
      return (
        expected.expectedSessionId === adoptedSessionId &&
        "expectedAudience" in expected &&
        expected.expectedAudience === this.canonicalApiOrigin
      );
    }
    return false;
  }

  private currentReconcileExpectation(): SessionLifecycleExpectation | undefined {
    if (this.snapshot.phase === "signed_in" || this.snapshot.phase === "signed_out") {
      return sessionExpectation(this.snapshot);
    }
    if (this.snapshot.phase !== "indeterminate" || !this.adoptedCookie) {
      return undefined;
    }
    const sessionId = this.adoptedCookie.sessionId;
    if (sessionId === undefined) {
      return undefined;
    }
    if (sessionId === null) {
      return {
        authorityInstanceId: this.authorityInstanceId,
        expectedSessionId: null,
        generation: this.snapshot.generation,
      };
    }
    return {
      authorityInstanceId: this.authorityInstanceId,
      expectedAudience: this.canonicalApiOrigin,
      expectedSessionId: sessionId,
      generation: this.snapshot.generation,
    };
  }

  private canStartAuthentication(expected: SessionAbsenceExpectation) {
    return (
      (this.snapshot.phase === "signed_out" ||
        this.snapshot.phase === "authenticating") &&
      expected.authorityInstanceId === this.authorityInstanceId &&
      expected.generation === this.snapshot.generation &&
      expected.expectedSessionId === null
    );
  }

  private canCommitAuthAttempt(
    record: Extract<
      WebSessionCoordinationRecord,
      { kind: "authenticating" | "stable" }
    >,
    expected: SessionAbsenceExpectation
  ) {
    return (
      this.canStartAuthentication(expected) &&
      this.adoptedCookie?.cookieAuthorityId === record.cookieAuthorityId &&
      this.adoptedCookie.cookieGeneration === record.cookieGeneration &&
      coordinationSessionId(record) === null
    );
  }

  private newAuthAttempt(expected: SessionAbsenceExpectation): SessionAuthAttemptRef {
    return {
      attemptId: this.ports.randomId(),
      expected,
    };
  }

  private isCurrentAuthAttempt(
    attempt: SessionAuthAttemptRef,
    operationEpoch?: number
  ) {
    return (
      this.authAttempt?.attempt.attemptId === attempt.attemptId &&
      this.authAttempt.attempt.expected.authorityInstanceId ===
        attempt.expected.authorityInstanceId &&
      this.authAttempt.attempt.expected.generation === attempt.expected.generation &&
      (operationEpoch === undefined ||
        this.authAttempt.operationEpoch === operationEpoch)
    );
  }

  private recordMatchesCurrentLease(
    record: Extract<
      WebSessionCoordinationRecord,
      { kind: "authenticating" | "stable" }
    >,
    sessionId: string
  ) {
    const adopted = this.adoptedCookie;
    return (
      record.kind === "stable" &&
      record.state.kind === "present" &&
      record.state.sessionId === sessionId &&
      adopted?.cookieAuthorityId === record.cookieAuthorityId &&
      adopted.cookieGeneration === record.cookieGeneration
    );
  }

  private recordMatchesLease(
    record: Extract<
      WebSessionCoordinationRecord,
      { kind: "authenticating" | "stable" }
    >,
    lease: WebCookieSessionProductLease
  ) {
    return (
      record.kind === "stable" &&
      record.state.kind === "present" &&
      record.state.sessionId === lease.sessionId &&
      record.cookieAuthorityId === lease.cookieAuthorityId &&
      record.cookieGeneration === lease.cookieGeneration
    );
  }

  private isCurrentProductLease(lease: WebCookieSessionProductLease) {
    const current = this.getProductLease();
    return (
      current !== undefined &&
      current.authorityInstanceId === lease.authorityInstanceId &&
      current.generation === lease.generation &&
      current.sessionId === lease.sessionId &&
      current.audience === lease.audience &&
      current.cookieAuthorityId === lease.cookieAuthorityId &&
      current.cookieGeneration === lease.cookieGeneration &&
      current.signal === lease.signal &&
      !lease.signal.aborted
    );
  }

  private isCurrentProductLeaseIdentity(lease: WebCookieSessionProductLease) {
    const current = sessionProductLease(this.snapshot);
    const adopted = this.adoptedCookie;
    return (
      current !== undefined &&
      current.authorityInstanceId === lease.authorityInstanceId &&
      current.generation === lease.generation &&
      current.sessionId === lease.sessionId &&
      current.audience === lease.audience &&
      adopted?.cookieAuthorityId === lease.cookieAuthorityId &&
      adopted.cookieGeneration === lease.cookieGeneration
    );
  }

  private cookieRecordCanReadmitReconcile(
    record: WebSessionCoordinationRecord,
    callerExpected: SessionLifecycleExpectation
  ) {
    if (!this.localExpectationMatches(callerExpected)) {
      return false;
    }
    const adopted = this.adoptedCookie;
    if (!adopted) {
      return this.snapshot.phase === "initializing";
    }
    if (
      record.cookieAuthorityId === adopted.cookieAuthorityId &&
      record.cookieGeneration === adopted.cookieGeneration
    ) {
      return true;
    }
    return (
      record.cookieAuthorityId !== adopted.cookieAuthorityId ||
      record.cookieGeneration > adopted.cookieGeneration
    );
  }

  private nextOperationEpoch() {
    this.operationEpoch += 1;
    return this.operationEpoch;
  }

  private isCurrentEpoch(epoch: number) {
    return epoch === this.operationEpoch;
  }

  private failure<
    Operation extends SessionOperationName,
    Code extends SessionOperationErrorCodeFor<Operation>,
  >(operation: Operation, code: Code): SessionOperationResult<never, Operation> {
    return {
      error: createSessionOperationError(operation, code, this.snapshot),
      ok: false,
    };
  }

  private handleLifecycleFailure(
    operation: "reconcile",
    error: unknown,
    epoch: number
  ): SessionOperationResult<never, "reconcile"> {
    if (
      error instanceof WebSessionLockTimeoutError &&
      this.keepSignedInThroughProbeFailure(epoch, this.adoptedCookie)
    ) {
      return this.failure(operation, "network_unavailable");
    }
    const code =
      error instanceof WebSessionUnsupportedError
        ? "unsupported"
        : error instanceof WebSessionStorageError
          ? "credential_store_unavailable"
          : error instanceof WebSessionLockTimeoutError
            ? "network_unavailable"
            : "unknown";
    if (this.isCurrentEpoch(epoch)) {
      this.publishIndeterminate(
        error instanceof WebSessionStorageError
          ? "credential_store_unavailable"
          : error instanceof WebSessionUnsupportedError
            ? "protocol_mismatch"
            : "session_probe_unavailable",
        this.snapshot.phase === "initializing" ? "initialize" : "reconcile"
      );
    }
    return this.failure(operation, code);
  }

  private handleOperationFailure<Operation extends SessionOperationName>(
    operation: Operation,
    error: unknown,
    epoch: number
  ): SessionOperationResult<never, Operation> {
    const code =
      error instanceof WebSessionUnsupportedError
        ? "unsupported"
        : error instanceof WebSessionStorageError
          ? "credential_store_unavailable"
          : error instanceof WebSessionLockTimeoutError
            ? "network_unavailable"
            : "unknown";
    if (
      this.isCurrentEpoch(epoch) &&
      (error instanceof WebSessionStorageError ||
        error instanceof WebSessionUnsupportedError ||
        (operation === "sign_out" && error instanceof WebSessionLockTimeoutError))
    ) {
      this.publishIndeterminate(
        error instanceof WebSessionStorageError
          ? "credential_store_unavailable"
          : error instanceof WebSessionUnsupportedError
            ? "protocol_mismatch"
            : "session_probe_unavailable",
        operation === "sign_out" ? "sign_out" : "authenticate"
      );
    }
    return {
      error: createSessionOperationErrorOrUnknown(operation, code, this.snapshot),
      ok: false,
    };
  }
}

function webSessionClientMetadata() {
  const userAgent =
    typeof navigator === "undefined" ? "" : navigator.userAgent.toLowerCase();

  let clientPlatform: "android" | "ios" | "linux" | "macos" | "unknown" | "windows" =
    "unknown";
  if (userAgent.includes("android")) {
    clientPlatform = "android";
  } else if (
    userAgent.includes("iphone") ||
    userAgent.includes("ipad") ||
    userAgent.includes("ipod")
  ) {
    clientPlatform = "ios";
  } else if (userAgent.includes("windows")) {
    clientPlatform = "windows";
  } else if (userAgent.includes("mac os") || userAgent.includes("macintosh")) {
    clientPlatform = "macos";
  } else if (userAgent.includes("linux")) {
    clientPlatform = "linux";
  }

  return {
    client_kind: "web",
    client_platform: clientPlatform,
  } as const;
}

function classifyNetworkFailure(_error: unknown): "network_unavailable" {
  return "network_unavailable";
}

function classifyAuthStartResponse(
  response: WebLifecycleResponse
): "network_unavailable" | "provider_unavailable" | "rate_limited" | "unknown" {
  if (response.status === 429) {
    return "rate_limited";
  }
  if (response.status >= 500) {
    return "provider_unavailable";
  }
  return "unknown";
}

async function parseJson<Schema extends z.ZodType>(
  response: WebLifecycleResponse,
  schema: Schema
): Promise<z.output<Schema> | undefined> {
  const parsed = schema.safeParse(response.body);
  return parsed.success ? parsed.data : undefined;
}

function normalizeBaseUrl(baseUrl: string, documentOrigin: string) {
  const normalized = new URL(baseUrl, documentOrigin);
  normalized.hash = "";
  normalized.search = "";
  normalized.pathname = normalized.pathname.replace(/\/+$/, "");
  return normalized.toString().replace(/\/+$/, "");
}

function joinUrl(baseUrl: string, path: string) {
  return `${baseUrl.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;
}
