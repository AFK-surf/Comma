import { randomUUID } from "node:crypto";
import {
  createSessionOperationErrorOrUnknown,
  createSessionProblem,
  sessionCancelAuthAttemptResultSchema,
  sessionExpectation,
  sessionGoogleSignInResultSchema,
  sessionLifecycleExpectationSchema,
  sessionOperationErrorRule,
  sessionReconcileResultSchema,
  sessionRequestEmailLoginResultSchema,
  sessionSignOutResultSchema,
  signedInSessionSnapshotSchema,
  sessionVerifyEmailLoginResultSchema,
  sessionVerifyGoogleLinkResultSchema,
  type SessionAbsenceExpectation,
  type SessionAdmissionFailure,
  type SessionAuthAttemptRef,
  type SessionCancelAuthAttemptInput,
  type SessionGoogleSignInInput,
  type SessionLifecycleExpectation,
  type SessionLifecycleSnapshot,
  type SessionOperationError,
  type SessionOperationErrorCode,
  type SessionOperationResult,
  type SessionOperationName,
  type SessionPresenceExpectation,
  type SessionReconcileInput,
  type SessionRequestEmailLoginInput,
  type SessionSignOutInput,
  type SessionVerifyLoginInput,
  type SignedInSessionSnapshot,
} from "@comma/session-contract";
import { z } from "zod";
import type { DesktopGoogleAuthProvider } from "../../google-desktop-auth";
import {
  SecureSessionStore,
  type SecureSessionVaultActive,
  type SecureSessionVaultSnapshot,
} from "../../secure-store";
import {
  MainProductCredentialAuthority,
  type MainProductCredentialLease,
} from "./main-product-credential-authority";
import {
  canonicalizeSessionAudience,
  secureSessionActiveCredentialSchema,
  type SecurePendingSessionRevocationRecord,
  type SecureSessionActiveCredential,
} from "./credential";

type ReconcileResult = z.output<typeof sessionReconcileResultSchema>;
type SignOutResult = z.output<typeof sessionSignOutResultSchema>;
type RequestEmailLoginResult = z.output<typeof sessionRequestEmailLoginResultSchema>;
type VerifyEmailLoginResult = z.output<typeof sessionVerifyEmailLoginResultSchema>;
type GoogleSignInResult = z.output<typeof sessionGoogleSignInResultSchema>;
type VerifyGoogleLinkResult = z.output<typeof sessionVerifyGoogleLinkResultSchema>;
type CancelAuthAttemptResult = z.output<typeof sessionCancelAuthAttemptResultSchema>;

const MAX_REVOCATION_DRAIN_PASSES = 4;
const MAX_REVOCATION_RECORDS_PER_PASS = 32;
const MAX_REVOCATION_RECORDS_PER_DRAIN =
  MAX_REVOCATION_DRAIN_PASSES * MAX_REVOCATION_RECORDS_PER_PASS;
const MAX_SUPERSEDED_AUTH_ATTEMPTS = 32;

const authUserSchema = z.object({
  email: z.string().min(1).max(320),
  id: z.string().min(1).max(256),
  name: z.string().max(512).nullable().optional(),
  status: z.string().max(128).nullable().optional(),
});

const issuedSessionSchema = z.object({
  expires_at: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  session_id: z.string().min(1).max(256),
  token: z.string().min(1).max(16_384),
  user: authUserSchema,
});

// Unknown fields are ignored so a newer backend stays compatible, but a probe
// must never reflect the bearer.
const currentSessionSchema = issuedSessionSchema
  .omit({ token: true })
  .extend({ token: z.never().optional() });

const emailChallengeSchema = z.object({
  challenge_id: z.string().min(1).max(256),
  code: z.string().min(1).max(32).optional(),
});

const googleAttemptSchema = z.object({
  attempt_id: z.string().min(1).max(256),
  client_id: z.string().min(1).max(2_048),
  nonce: z.string().min(1).max(2_048),
  platform: z.literal("electron"),
});

const googleLinkChallengeSchema = z.object({
  challenge_id: z.string().min(1).max(256),
  code: z.string().min(1).max(32).optional(),
  email: z.string().min(1).max(320),
  status: z.literal("otp_required"),
});

const googleResultSchema = z.union([issuedSessionSchema, googleLinkChallengeSchema]);

const signedOutRemoteSchema = z.object({
  signed_out: z.literal(true),
});

interface AuthAttemptState {
  attempt: SessionAuthAttemptRef;
  challengeId?: string | undefined;
  cleanupSettled: boolean;
  committingCredential?: SecureSessionActiveCredential | undefined;
  controller: AbortController;
  inFlight?: {
    promise: Promise<void>;
    resolve: () => void;
  };
  kind: "email" | "google";
  operationEpoch: number;
  providerAttemptId?: string | undefined;
  providerNonce?: string | undefined;
  supersededAttempts: AuthAttemptState[];
}

export interface ElectronMainSessionServiceOptions {
  authorityInstanceId?: string | undefined;
  fetch?: typeof fetch | undefined;
  googleAuth?: DesktopGoogleAuthProvider | undefined;
  onSnapshotChanged?:
    | ((snapshot: SessionLifecycleSnapshot) => Promise<void> | void)
    | undefined;
  remoteTimeoutMs?: number | undefined;
  store: SecureSessionStore;
  trustedAudience: string;
}

class RemoteOperationError extends Error {
  constructor(
    readonly code: SessionOperationErrorCode | "unauthorized",
    readonly retryAfterMs?: number | undefined
  ) {
    super(code);
  }
}

const unavailableDesktopGoogleAuth: DesktopGoogleAuthProvider = {
  async authenticate() {
    throw new RemoteOperationError("unsupported");
  },
};

/**
 * Main's narrow Session coordinator. SecureSessionStore owns durable custody;
 * MainProductCredentialAuthority owns the synchronous bearer gate; this class
 * coordinates remote reconciliation/authentication and typed lifecycle results.
 */
export class ElectronMainSessionService {
  readonly #authority: MainProductCredentialAuthority;
  #authAttempt: AuthAttemptState | undefined;
  #closed = false;
  #commitTail: Promise<void> = Promise.resolve();
  readonly #fetch: typeof fetch;
  readonly #googleAuth: DesktopGoogleAuthProvider;
  #initialized = false;
  #operationEpoch = 0;
  readonly #remoteTimeoutMs: number;
  #revocationRetry: Promise<void> | undefined;
  #startupReconcileAvailable = true;
  readonly #store: SecureSessionStore;
  readonly #trustedAudience: string;
  readonly #unresolvedIssuedCredentials = new Map<
    string,
    SecureSessionActiveCredential
  >();

  constructor(options: ElectronMainSessionServiceOptions) {
    this.#store = options.store;
    this.#fetch = options.fetch ?? fetch;
    this.#googleAuth = options.googleAuth ?? unavailableDesktopGoogleAuth;
    this.#trustedAudience = canonicalizeSessionAudience(options.trustedAudience);
    this.#remoteTimeoutMs = normalizeTimeout(options.remoteTimeoutMs, 5_000);

    const vault = this.#store.getVaultSnapshot();
    const active = vault.status === "readable" ? vault.active : undefined;
    const persistedCredential = active ? activeCredential(active) : undefined;
    this.#authority = new MainProductCredentialAuthority({
      authorityInstanceId: options.authorityInstanceId ?? randomUUID(),
      cleanup: vault.cleanup,
      onSnapshotChanged: options.onSnapshotChanged,
      ...(persistedCredential ? { persistedCredential } : {}),
      trustedAudience: this.#trustedAudience,
    });

    if (vault.status === "indeterminate") {
      this.#authority.markIndeterminate(vault.problem);
    } else if (hasUntrustedPendingAudience(vault, this.#trustedAudience)) {
      this.#authority.markIndeterminate(
        createSessionProblem("protocol_mismatch", "initialize")
      );
    }
  }

  get authority(): MainProductCredentialAuthority {
    return this.#authority;
  }

  state(): SessionLifecycleSnapshot {
    return this.#authority.getSnapshot();
  }

  async initialize(): Promise<ReconcileResult> {
    if (this.#initialized) {
      return this.reconcile({
        expected: lifecycleExpectationOrUndefined(this.state()),
        reason: "manual_retry",
      });
    }

    this.#initialized = true;
    const result = await this.reconcile({ reason: "startup" });
    if (result.ok) void this.retryPendingRevocations();
    return result;
  }

  acquireProductCredential(
    expected: SessionPresenceExpectation
  ): MainProductCredentialLease | null {
    return this.#authority.acquireProductCredential(expected);
  }

  isCurrentProductCredential(lease: MainProductCredentialLease): boolean {
    return this.#authority.isCurrentProductCredential(lease);
  }

  admissionFailure(): SessionAdmissionFailure {
    return this.#authority.admissionFailure();
  }

  async reportUnauthorized(lease: MainProductCredentialLease): Promise<void> {
    const expected = leaseExpectation(lease);
    if (!this.#authority.beginInvalidation(expected)) return;
    const operationEpoch = this.#advanceOperationEpoch();

    await this.#withCommitFence(async () => {
      if (!this.#isCurrentOperation(operationEpoch) || this.#closed) return;
      try {
        const removed = await this.#store.invalidateSession({
          audience: lease.audience,
          sessionId: lease.sessionId,
          token: lease.token,
        });
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) return;
        if (!removed) {
          this.#authority.markIndeterminate(
            createSessionProblem("credential_mutation_uncertain", "invalidate")
          );
          return;
        }
        this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
        this.#authority.settleSignedOut("unauthorized");
      } catch {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) return;
        this.#authority.markIndeterminate(
          createSessionProblem("credential_mutation_uncertain", "invalidate")
        );
      }
    });
  }

  async reconcile(input: SessionReconcileInput): Promise<ReconcileResult> {
    const operation = "reconcile" as const;
    const currentSnapshot = this.state();
    const startupWithoutExpectation =
      input.reason === "startup" &&
      input.expected === undefined &&
      this.#startupReconcileAvailable;
    const indeterminateRetry =
      input.reason === "manual_retry" &&
      input.expected === undefined &&
      currentSnapshot.phase === "indeterminate";

    if (
      !startupWithoutExpectation &&
      !indeterminateRetry &&
      !this.#matchesExpectation(input.expected)
    ) {
      return this.#errorResult(operation, "conflict");
    }
    if (
      input.expected === undefined &&
      !startupWithoutExpectation &&
      !indeterminateRetry
    ) {
      return this.#errorResult(operation, "conflict");
    }
    if (currentSnapshot.phase === "authenticating") {
      return this.#errorResult(operation, "conflict");
    }
    this.#startupReconcileAvailable = false;
    const operationEpoch = this.#advanceOperationEpoch();

    if (
      this.#unresolvedIssuedCredentials.size > 0 &&
      !(await this.#retryUnresolvedIssuedCleanup())
    ) {
      return this.#withCommitFence(() =>
        !this.#isCurrentOperation(operationEpoch) || this.#closed
          ? this.#errorResult(operation, "conflict")
          : this.#markProblemResult(
              operation,
              "credential_mutation_uncertain",
              "reconcile"
            )
      );
    }

    let vault: SecureSessionVaultSnapshot;
    try {
      await this.#store.refresh();
      vault = this.#store.getVaultSnapshot();
    } catch {
      return this.#withCommitFence(() =>
        !this.#isCurrentOperation(operationEpoch) || this.#closed
          ? this.#errorResult(operation, "conflict")
          : this.#markProblemResult(
              operation,
              "credential_store_unreadable",
              "reconcile"
            )
      );
    }

    if (vault.status === "indeterminate") {
      const problem = vault.problem;
      return this.#withCommitFence(() => {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        this.#authority.markIndeterminate(problem);
        return this.#errorResult(operation, problem.code);
      });
    }

    if (
      (vault.active && vault.active.audience !== this.#trustedAudience) ||
      hasUntrustedPendingAudience(vault, this.#trustedAudience)
    ) {
      const previousVault = vault;
      const cleaned = await this.#withCommitFence(async () => {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        this.#authority.closeProductCredentialGate();
        try {
          // A configured backend change retires only credentials for other origins.
          // Local removal does not claim remote revocation or contact the old origin.
          const committed = await this.#store.compareAndSetVault(previousVault, {
            ...(previousVault.active?.audience === this.#trustedAudience
              ? { active: activeCredential(previousVault.active) }
              : {}),
            pendingRevocations: previousVault.pendingRevocations.filter(
              (pending) => pending.audience === this.#trustedAudience
            ),
          });
          if (!committed || !this.#isCurrentOperation(operationEpoch) || this.#closed) {
            return this.#errorResult(operation, "conflict");
          }
          return committed;
        } catch {
          if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
            return this.#errorResult(operation, "conflict");
          }
          return this.#markProblemResult(
            operation,
            "credential_mutation_uncertain",
            "reconcile"
          );
        }
      });
      if ("ok" in cleaned) return cleaned;
      if (cleaned.status !== "readable") {
        this.#authority.markIndeterminate(cleaned.problem);
        return this.#errorResult(operation, cleaned.problem.code);
      }
      vault = cleaned;
    }

    if (!vault.active) {
      return this.#withCommitFence(() => {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
        return sessionReconcileResultSchema.parse({
          ok: true,
          value: this.#authority.settleSignedOut("no_session"),
        });
      });
    }

    const active = vault.active;
    const probe = await this.#probeActiveCredential(active);
    return this.#withCommitFence(async () => {
      if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
        return this.#errorResult(operation, "conflict");
      }

      if (probe.kind === "error") {
        return this.#markProblemResult(operation, probe.code, "reconcile");
      }

      if (probe.kind === "unauthorized") {
        try {
          await this.#store.invalidateSession({
            audience: active.audience,
            sessionId: active.sessionId,
            token: active.token,
          });
          if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
            return this.#errorResult(operation, "conflict");
          }
          this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
          return sessionReconcileResultSchema.parse({
            ok: true,
            value: this.#authority.settleSignedOut("unauthorized"),
          });
        } catch {
          if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
            return this.#errorResult(operation, "conflict");
          }
          return this.#markProblemResult(
            operation,
            "credential_mutation_uncertain",
            "reconcile"
          );
        }
      }

      const credential = credentialFromRemote(
        active.token,
        active.audience,
        probe.value
      );
      try {
        const durable = await this.#persistReconciledCredential(active, credential);
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        if (!durable) return this.#errorResult(operation, "conflict");
        this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
      } catch {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        return this.#markProblemResult(
          operation,
          "credential_mutation_uncertain",
          "reconcile"
        );
      }

      const snapshot = this.#authority.acceptVerifiedCredential(credential);
      void this.retryPendingRevocations();
      return sessionReconcileResultSchema.parse({ ok: true, value: snapshot });
    });
  }

  async requestEmailLogin(
    input: SessionRequestEmailLoginInput
  ): Promise<RequestEmailLoginResult> {
    const operation = "request_email_login" as const;
    const attempt = this.#startAuthAttempt("email", input.expected);
    if (!attempt) return this.#errorResult(operation, "conflict");
    const finish = this.#beginAuthAttemptOperation(attempt);
    if (!finish) return this.#errorResult(operation, "conflict");

    try {
      const challenge = await this.#requestJson(
        "/v1/comma/auth/email/login",
        {
          body: { email: input.email },
          method: "POST",
          signal: attempt.controller.signal,
        },
        emailChallengeSchema
      );
      if (!this.#isCurrentAttempt(attempt)) {
        return this.#errorResult(operation, "cancelled");
      }
      attempt.challengeId = challenge.challenge_id;
      return sessionRequestEmailLoginResultSchema.parse({
        ok: true,
        value: {
          attempt: attempt.attempt,
          challengeId: challenge.challenge_id,
        },
      });
    } catch (error) {
      return this.#settleAuthError(operation, attempt, error, {
        retainRetryableAttempt: false,
      });
    } finally {
      finish();
    }
  }

  async verifyEmailLogin(
    input: SessionVerifyLoginInput
  ): Promise<VerifyEmailLoginResult> {
    const operation = "verify_email_login" as const;
    const attempt = this.#matchingAttempt(input, "email");
    if (!attempt) return this.#errorResult(operation, "conflict");
    const finish = this.#beginAuthAttemptOperation(attempt);
    if (!finish) return this.#errorResult(operation, "conflict");

    try {
      const issued = await this.#requestJson(
        "/v1/comma/auth/email/verify",
        {
          body: {
            challenge_id: input.challengeId,
            code: input.code,
            ...electronSessionClientMetadata(),
          },
          method: "POST",
          signal: attempt.controller.signal,
        },
        issuedSessionSchema
      );
      return await this.#commitIssuedSession(operation, attempt, issued);
    } catch (error) {
      return this.#settleAuthError(operation, attempt, error);
    } finally {
      finish();
    }
  }

  async signInWithGoogle(input: SessionGoogleSignInInput): Promise<GoogleSignInResult> {
    const operation = "sign_in_with_google" as const;
    const attempt = this.#startAuthAttempt("google", input.expected);
    if (!attempt) return this.#errorResult(operation, "conflict");
    const finish = this.#beginAuthAttemptOperation(attempt);
    if (!finish) return this.#errorResult(operation, "conflict");

    let authorization:
      | Awaited<ReturnType<DesktopGoogleAuthProvider["authenticate"]>>
      | undefined;

    try {
      const remoteAttempt = await this.#requestJson(
        "/v1/comma/auth/google/attempt",
        {
          body: { platform: "electron" },
          method: "POST",
          signal: attempt.controller.signal,
        },
        googleAttemptSchema
      );
      attempt.providerAttemptId = remoteAttempt.attempt_id;
      attempt.providerNonce = remoteAttempt.nonce;
      authorization = await this.#googleAuth.authenticate({
        clientId: remoteAttempt.client_id,
        nonce: remoteAttempt.nonce,
        signal: attempt.controller.signal,
      });
      const result = await this.#requestJson(
        "/v1/comma/auth/google",
        {
          body: {
            attempt_id: remoteAttempt.attempt_id,
            authorization_code: authorization.authorizationCode,
            code_verifier: authorization.codeVerifier,
            nonce: remoteAttempt.nonce,
            redirect_uri: authorization.redirectUri,
            ...electronSessionClientMetadata(),
          },
          method: "POST",
          signal: attempt.controller.signal,
        },
        googleResultSchema
      );

      if ("status" in result) {
        const completed = sessionGoogleSignInResultSchema.parse({
          ok: true,
          value: {
            attempt: attempt.attempt,
            challengeId: result.challenge_id,
            email: result.email,
            status: "otp_required",
          },
        });
        attempt.challengeId = result.challenge_id;
        // Protocol anchor: tla/google_desktop_auth/GoogleDesktopAuth.tla
        authorization.complete(true);
        return completed;
      }

      const committed = await this.#commitIssuedSession(operation, attempt, result);
      if (!committed.ok) {
        authorization.complete(false);
        return committed;
      }
      const completed = sessionGoogleSignInResultSchema.parse({
        ok: true,
        value: {
          snapshot: committed.value,
          status: "signed_in",
        },
      });
      authorization.complete(true);
      return completed;
    } catch (error) {
      authorization?.complete(false);
      return this.#settleAuthError(operation, attempt, error, {
        retainRetryableAttempt: false,
      });
    } finally {
      finish();
    }
  }

  async verifyGoogleLink(
    input: SessionVerifyLoginInput
  ): Promise<VerifyGoogleLinkResult> {
    const operation = "verify_google_link" as const;
    const attempt = this.#matchingAttempt(input, "google");
    if (!attempt) return this.#errorResult(operation, "conflict");
    const finish = this.#beginAuthAttemptOperation(attempt);
    if (!finish) return this.#errorResult(operation, "conflict");

    try {
      const issued = await this.#requestJson(
        "/v1/comma/auth/google/link/verify",
        {
          body: {
            challenge_id: input.challengeId,
            code: input.code,
            ...electronSessionClientMetadata(),
          },
          method: "POST",
          signal: attempt.controller.signal,
        },
        issuedSessionSchema
      );
      return await this.#commitIssuedSession(operation, attempt, issued);
    } catch (error) {
      return this.#settleAuthError(operation, attempt, error);
    } finally {
      finish();
    }
  }

  async cancelAuthAttempt(
    input: SessionCancelAuthAttemptInput
  ): Promise<CancelAuthAttemptResult> {
    const operation = "cancel_auth_attempt" as const;
    const attempt = this.#authAttempt;
    if (!attempt || !sameAuthAttempt(attempt.attempt, input.attempt)) {
      return this.#errorResult(operation, "conflict");
    }

    const retiredAttempts = [attempt, ...attempt.supersededAttempts];
    const inFlight = retiredAttempts.flatMap((candidate) =>
      candidate.inFlight ? [candidate.inFlight.promise] : []
    );
    const operationEpoch = this.#retireAuthAttempt();
    this.#authority.beginSignOut();
    await Promise.all(inFlight);

    return this.#withCommitFence(async () => {
      if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
        return this.#errorResult(operation, "conflict");
      }
      try {
        if (!(await this.#retryUnsettledAttemptCleanup(retiredAttempts))) {
          return this.#markProblemResult(
            operation,
            "credential_mutation_uncertain",
            "authenticate"
          );
        }
        await this.#store.beginSignOut();
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
        const signedOut = this.#authority.settleSignedOut("no_session");
        void this.retryPendingRevocations();
        return sessionCancelAuthAttemptResultSchema.parse({
          ok: true,
          value: signedOut,
        });
      } catch {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        return this.#markProblemResult(
          operation,
          "credential_mutation_uncertain",
          "sign_out"
        );
      }
    });
  }

  async signOut(input: SessionSignOutInput): Promise<SignOutResult> {
    const operation = "sign_out" as const;
    const snapshot = this.state();
    if (!this.#matchesExpectation(input.expected)) {
      return this.#errorResult(operation, "conflict");
    }
    if (snapshot.phase === "signed_out") {
      return sessionSignOutResultSchema.parse({ ok: true, value: snapshot });
    }
    if (
      snapshot.phase === "initializing" ||
      snapshot.phase === "indeterminate" ||
      snapshot.phase === "signing_out" ||
      snapshot.phase === "invalidating"
    ) {
      return this.#errorResult(operation, "conflict");
    }

    const retiringAttempt = this.#authAttempt;
    const retiredAttempts = retiringAttempt
      ? [retiringAttempt, ...retiringAttempt.supersededAttempts]
      : [];
    const inFlight = retiredAttempts.flatMap((candidate) =>
      candidate.inFlight ? [candidate.inFlight.promise] : []
    );
    const operationEpoch = this.#retireAuthAttempt();
    this.#authority.beginSignOut();
    await Promise.all(inFlight);

    return this.#withCommitFence(async () => {
      if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
        return this.#errorResult(operation, "conflict");
      }
      try {
        if (!(await this.#retryUnsettledAttemptCleanup(retiredAttempts))) {
          return this.#markProblemResult(
            operation,
            "credential_mutation_uncertain",
            "authenticate"
          );
        }
        await this.#store.beginSignOut();
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
        const signedOut = this.#authority.settleSignedOut("user_signed_out");
        void this.retryPendingRevocations();
        return sessionSignOutResultSchema.parse({ ok: true, value: signedOut });
      } catch {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "conflict");
        }
        return this.#markProblemResult(
          operation,
          "credential_mutation_uncertain",
          "sign_out"
        );
      }
    });
  }

  retryPendingRevocations(): Promise<void> {
    if (this.#revocationRetry) return this.#revocationRetry;
    const retry = this.#runPendingRevocations().finally(() => {
      if (this.#revocationRetry === retry) this.#revocationRetry = undefined;
    });
    this.#revocationRetry = retry;
    return retry;
  }

  async #runPendingRevocations(): Promise<void> {
    const attempted = new Set<string>();
    let attemptedCount = 0;

    for (
      let pass = 0;
      pass < MAX_REVOCATION_DRAIN_PASSES &&
      attemptedCount < MAX_REVOCATION_RECORDS_PER_DRAIN;
      pass += 1
    ) {
      if (this.#closed) return;
      const vault = this.#store.getVaultSnapshot();
      const snapshot = this.state();
      if (
        vault.status !== "readable" ||
        vault.pendingRevocations.some(
          (pending) => pending.audience !== this.#trustedAudience
        ) ||
        (snapshot.phase === "indeterminate" &&
          snapshot.problem.code === "protocol_mismatch")
      ) {
        return;
      }

      const remaining = MAX_REVOCATION_RECORDS_PER_DRAIN - attemptedCount;
      const pending = vault.pendingRevocations
        .filter((record) => !attempted.has(pendingRevocationKey(record)))
        .slice(0, Math.min(MAX_REVOCATION_RECORDS_PER_PASS, remaining));
      if (pending.length === 0) break;

      for (const record of pending) {
        attempted.add(pendingRevocationKey(record));
        attemptedCount += 1;
        await this.#retryPendingRevocation(record);
      }
    }

    await this.#withCommitFence(() => {
      if (!this.#closed) {
        this.#authority.updateCleanup(this.#store.getVaultSnapshot().cleanup);
      }
    });
  }

  async close(): Promise<void> {
    if (this.#closed && this.#unresolvedIssuedCredentials.size === 0) return;
    let retiredAttempts: AuthAttemptState[] = [];
    if (!this.#closed) {
      const retiringAttempt = this.#authAttempt;
      retiredAttempts = retiringAttempt
        ? [retiringAttempt, ...retiringAttempt.supersededAttempts]
        : [];
      const inFlight = retiredAttempts.flatMap((candidate) =>
        candidate.inFlight ? [candidate.inFlight.promise] : []
      );
      this.#retireAuthAttempt();
      this.#closed = true;
      this.#authority.close();
      await Promise.all(inFlight);
    }
    await this.#withCommitFence(() =>
      this.#retryUnsettledAttemptCleanup(retiredAttempts)
    );
    if (!(await this.#retryUnresolvedIssuedCleanup())) {
      throw new Error(
        "Electron Main closed with an issued credential that could not be quarantined."
      );
    }
  }

  #startAuthAttempt(
    kind: AuthAttemptState["kind"],
    expected: SessionAbsenceExpectation
  ): AuthAttemptState | undefined {
    if (!this.#matchesExpectation(expected)) return undefined;
    const snapshot = this.state();
    if (snapshot.phase !== "signed_out" && snapshot.phase !== "authenticating") {
      return undefined;
    }
    const supersededAttempts = supersededAuthAttempts(this.#authAttempt);
    if (!supersededAttempts) return undefined;
    const operationEpoch = this.#retireAuthAttempt();
    if (!this.#authority.beginAuthentication()) return undefined;
    const attempt: AuthAttemptState = {
      attempt: {
        attemptId: randomUUID(),
        expected,
      },
      cleanupSettled: true,
      controller: new AbortController(),
      kind,
      operationEpoch,
      supersededAttempts,
    };
    this.#authAttempt = attempt;
    return attempt;
  }

  #matchingAttempt(
    input: SessionVerifyLoginInput,
    kind: AuthAttemptState["kind"]
  ): AuthAttemptState | undefined {
    const attempt = this.#authAttempt;
    if (
      !attempt ||
      attempt.kind !== kind ||
      attempt.challengeId !== input.challengeId ||
      !sameAuthAttempt(attempt.attempt, input.attempt)
    ) {
      return undefined;
    }
    return attempt;
  }

  async #commitIssuedSession<
    Operation extends
      | "verify_email_login"
      | "sign_in_with_google"
      | "verify_google_link",
  >(
    operation: Operation,
    attempt: AuthAttemptState,
    issued: z.output<typeof issuedSessionSchema>
  ): Promise<SessionOperationResult<SignedInSessionSnapshot, Operation>> {
    const credential = credentialFromRemote(
      issued.token,
      this.#trustedAudience,
      issued
    );
    attempt.committingCredential = credential;
    attempt.cleanupSettled = false;
    this.#rememberUnresolvedIssuedCredential(credential);
    await Promise.all(
      attempt.supersededAttempts.flatMap((superseded) =>
        superseded.inFlight ? [superseded.inFlight.promise] : []
      )
    );
    const supersededCredentials = issuedCredentialsForAttempts(
      attempt.supersededAttempts
    );
    const settlement = await this.#withCommitFence(async () => {
      if (!this.#isCurrentAttempt(attempt) || this.#closed) {
        const queued = await this.#queueStaleCredential(credential);
        attempt.cleanupSettled = queued;
        if (queued) this.#forgetUnresolvedIssuedCredential(credential);
        return {
          kind: "cancelled" as const,
          needsRemoteCleanup: !queued,
        };
      }

      try {
        await this.#store.setSession(credential, {
          supersededCredentials,
        });
      } catch {
        const queued = await this.#queueStaleCredential(credential);
        attempt.cleanupSettled = queued;
        if (queued) this.#forgetUnresolvedIssuedCredential(credential);
        if (!this.#isCurrentAttempt(attempt) || this.#closed) {
          return {
            kind: "cancelled" as const,
            needsRemoteCleanup: !queued,
          };
        }
        this.#retireAuthAttempt();
        return {
          kind: "error" as const,
          needsRemoteCleanup: !queued,
          result: this.#markProblemResult(
            operation,
            "credential_mutation_uncertain",
            "authenticate"
          ),
        };
      }

      if (!this.#isCurrentAttempt(attempt) || this.#closed) {
        const queued = await this.#queueStaleCredential(credential);
        attempt.cleanupSettled = queued;
        if (queued) this.#forgetUnresolvedIssuedCredential(credential);
        return {
          kind: "cancelled" as const,
          needsRemoteCleanup: !queued,
        };
      }

      for (const superseded of attempt.supersededAttempts) {
        superseded.cleanupSettled = true;
        if (superseded.committingCredential) {
          this.#forgetUnresolvedIssuedCredential(superseded.committingCredential);
        }
      }
      attempt.cleanupSettled = true;
      this.#forgetUnresolvedIssuedCredential(credential);
      this.#authAttempt = undefined;
      const snapshot = signedInSessionSnapshotSchema.parse(
        this.#authority.acceptVerifiedCredential(credential)
      );
      return {
        kind: "success" as const,
        needsRemoteCleanup: false,
        result: { ok: true as const, value: snapshot },
      };
    });

    if (settlement.needsRemoteCleanup) {
      attempt.cleanupSettled = await this.#revokeIssuedCredentialRemotely(credential);
      if (attempt.cleanupSettled) {
        this.#forgetUnresolvedIssuedCredential(credential);
      }
    } else {
      void this.retryPendingRevocations();
    }

    if (settlement.kind === "success" || settlement.kind === "error") {
      return settlement.result;
    }
    return this.#errorResult(operation, "cancelled");
  }

  async #persistReconciledCredential(
    previous: SecureSessionVaultActive,
    credential: SecureSessionActiveCredential
  ): Promise<boolean> {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const vault = this.#store.getVaultSnapshot();
      if (
        vault.status !== "readable" ||
        !vault.active ||
        vault.active.token !== previous.token ||
        vault.active.audience !== previous.audience
      ) {
        return false;
      }
      const committed = await this.#store.compareAndSetVault(
        {
          sourceIdentity: vault.sourceIdentity,
          vaultRevision: vault.vaultRevision,
        },
        {
          active: credential,
          pendingRevocations: vault.pendingRevocations,
        }
      );
      if (committed) return true;
    }
    return false;
  }

  async #probeActiveCredential(active: SecureSessionVaultActive): Promise<
    | { kind: "ok"; value: z.output<typeof currentSessionSchema> }
    | { kind: "unauthorized" }
    | {
        code: "protocol_mismatch" | "session_probe_unavailable";
        kind: "error";
      }
  > {
    try {
      return {
        kind: "ok",
        value: await this.#requestJson(
          "/v1/comma/auth/session",
          {
            method: "GET",
            token: active.token,
          },
          currentSessionSchema
        ),
      };
    } catch (error) {
      if (error instanceof RemoteOperationError && error.code === "unauthorized") {
        return { kind: "unauthorized" };
      }
      if (error instanceof RemoteOperationError && error.code === "protocol_mismatch") {
        return { code: "protocol_mismatch", kind: "error" };
      }
      return { code: "session_probe_unavailable", kind: "error" };
    }
  }

  async #requestJson<Schema extends z.ZodType>(
    path: string,
    options: {
      body?: Record<string, unknown> | undefined;
      method: "GET" | "POST";
      signal?: AbortSignal | undefined;
      token?: string | undefined;
    },
    schema: Schema
  ): Promise<z.output<Schema>> {
    const timeout = new AbortController();
    const timer = setTimeout(() => timeout.abort(), this.#remoteTimeoutMs);
    const signal = options.signal
      ? AbortSignal.any([options.signal, timeout.signal])
      : timeout.signal;
    const headers = new Headers({
      accept: "application/json",
      "x-comma-session-transport": "bearer",
    });
    if (options.body) headers.set("content-type", "application/json");
    if (options.token) headers.set("authorization", `Bearer ${options.token}`);

    try {
      let response: Response;
      try {
        response = await this.#fetch(new URL(path, this.#trustedAudience), {
          ...(options.body ? { body: JSON.stringify(options.body) } : {}),
          credentials: "omit",
          headers,
          method: options.method,
          redirect: "manual",
          signal,
        });
      } catch {
        if (options.signal?.aborted) throw new RemoteOperationError("cancelled");
        throw new RemoteOperationError("network_unavailable");
      }

      if (response.status >= 300 && response.status < 400) {
        throw new RemoteOperationError("protocol_mismatch");
      }
      if (!response.ok) {
        throw await remoteErrorForResponse(response);
      }

      let value: unknown;
      try {
        value = await response.json();
      } catch {
        if (options.signal?.aborted) {
          throw new RemoteOperationError("cancelled");
        }
        if (timeout.signal.aborted) {
          throw new RemoteOperationError("network_unavailable");
        }
        throw new RemoteOperationError("protocol_mismatch");
      }
      const decoded = schema.safeParse(value);
      if (!decoded.success) throw new RemoteOperationError("protocol_mismatch");
      return decoded.data;
    } finally {
      clearTimeout(timer);
    }
  }

  async #retryPendingRevocation(
    pending: SecurePendingSessionRevocationRecord
  ): Promise<void> {
    let terminal = false;
    try {
      await this.#requestJson(
        "/v1/comma/auth/logout",
        {
          body: {},
          method: "POST",
          token: pending.token,
        },
        signedOutRemoteSchema
      );
      terminal = true;
    } catch (error) {
      if (error instanceof RemoteOperationError && error.code === "unauthorized") {
        terminal = true;
      }
    }
    if (!terminal) return;

    try {
      await this.#store.completeRevocation(pending);
    } catch {
      // The durable record remains pending; other bounded cleanup records can proceed.
    }
  }

  async #revokeIssuedCredentialRemotely(
    credential: SecureSessionActiveCredential
  ): Promise<boolean> {
    try {
      await this.#requestJson(
        "/v1/comma/auth/logout",
        {
          body: {},
          method: "POST",
          token: credential.token,
        },
        signedOutRemoteSchema
      );
      return true;
    } catch (error) {
      return error instanceof RemoteOperationError && error.code === "unauthorized";
    }
  }

  async #queueStaleCredential(
    credential: SecureSessionActiveCredential
  ): Promise<boolean> {
    const snapshot = this.state();
    const vault = this.#store.getVaultSnapshot();
    if (
      snapshot.phase === "signed_in" &&
      snapshot.session.audience === credential.audience &&
      snapshot.session.sessionId === credential.sessionId &&
      vault.status === "readable" &&
      vault.active &&
      sameCredentialIdentity(activeCredential(vault.active), credential)
    ) {
      return true;
    }
    return (await this.#store.queueRevocation(credential)) === true;
  }

  async #retryUnsettledAttemptCleanup(
    attempts: readonly AuthAttemptState[]
  ): Promise<boolean> {
    for (const attempt of new Set(attempts)) {
      if (attempt.cleanupSettled) continue;
      if (!attempt.committingCredential) return false;
      attempt.cleanupSettled = await this.#queueStaleCredential(
        attempt.committingCredential
      );
      if (attempt.cleanupSettled) {
        this.#forgetUnresolvedIssuedCredential(attempt.committingCredential);
      }
      if (!attempt.cleanupSettled) return false;
    }
    return true;
  }

  async #retryUnresolvedIssuedCleanup(): Promise<boolean> {
    for (const credential of this.#unresolvedIssuedCredentials.values()) {
      if (await this.#queueStaleCredential(credential)) {
        this.#forgetUnresolvedIssuedCredential(credential);
        continue;
      }
      if (await this.#revokeIssuedCredentialRemotely(credential)) {
        this.#forgetUnresolvedIssuedCredential(credential);
      }
    }
    return this.#unresolvedIssuedCredentials.size === 0;
  }

  #rememberUnresolvedIssuedCredential(credential: SecureSessionActiveCredential): void {
    this.#unresolvedIssuedCredentials.set(issuedCredentialKey(credential), credential);
  }

  #forgetUnresolvedIssuedCredential(credential: SecureSessionActiveCredential): void {
    this.#unresolvedIssuedCredentials.delete(issuedCredentialKey(credential));
  }

  async #settleAuthError<Operation extends SessionOperationName>(
    operation: Operation,
    attempt: AuthAttemptState,
    error: unknown,
    options: { retainRetryableAttempt?: boolean } = {}
  ): Promise<{ error: SessionOperationError<Operation>; ok: false }> {
    const code =
      error instanceof RemoteOperationError && error.code !== "unauthorized"
        ? error.code
        : "unknown";
    const retryAfterMs =
      error instanceof RemoteOperationError ? error.retryAfterMs : undefined;
    const policy = sessionOperationErrorRule(operation, code);

    if (!this.#isCurrentAttempt(attempt)) {
      return this.#errorResult(operation, "cancelled");
    }
    if (!policy?.retryable || options.retainRetryableAttempt === false) {
      const retiredAttempts = [attempt, ...attempt.supersededAttempts];
      const supersededInFlight = attempt.supersededAttempts.flatMap((candidate) =>
        candidate.inFlight ? [candidate.inFlight.promise] : []
      );
      const operationEpoch = this.#advanceOperationEpoch();
      attempt.controller.abort();
      await Promise.all(supersededInFlight);
      if (this.#authAttempt === attempt) {
        this.#authAttempt = undefined;
      }
      return this.#withCommitFence(async () => {
        if (!this.#isCurrentOperation(operationEpoch) || this.#closed) {
          return this.#errorResult(operation, "cancelled");
        }
        if (!(await this.#retryUnsettledAttemptCleanup(retiredAttempts))) {
          return this.#markProblemResult(
            operation,
            "credential_mutation_uncertain",
            "authenticate"
          );
        }
        this.#authority.settleSignedOut("no_session");
        return this.#errorResult(operation, code, retryAfterMs);
      });
    }
    return this.#errorResult(operation, code, retryAfterMs);
  }

  #beginAuthAttemptOperation(attempt: AuthAttemptState): (() => void) | undefined {
    if (attempt.inFlight) return undefined;
    let resolve!: () => void;
    const promise = new Promise<void>((resolvePromise) => {
      resolve = resolvePromise;
    });
    const inFlight = { promise, resolve };
    attempt.inFlight = inFlight;
    return () => {
      if (attempt.inFlight === inFlight) {
        delete attempt.inFlight;
      }
      resolve();
    };
  }

  #withCommitFence<T>(work: () => Promise<T> | T): Promise<T> {
    const result = this.#commitTail.then(work);
    this.#commitTail = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  }

  #retireAuthAttempt(): number {
    const operationEpoch = this.#advanceOperationEpoch();
    this.#authAttempt?.controller.abort();
    this.#authAttempt = undefined;
    return operationEpoch;
  }

  #advanceOperationEpoch(): number {
    this.#operationEpoch = increment(this.#operationEpoch);
    return this.#operationEpoch;
  }

  #isCurrentOperation(operationEpoch: number): boolean {
    return operationEpoch === this.#operationEpoch;
  }

  #isCurrentAttempt(attempt: AuthAttemptState): boolean {
    return (
      this.#authAttempt === attempt &&
      !attempt.controller.signal.aborted &&
      attempt.operationEpoch === this.#operationEpoch
    );
  }

  #matchesExpectation(expectedValue: SessionLifecycleExpectation | undefined): boolean {
    const expected = sessionLifecycleExpectationSchema.safeParse(expectedValue);
    if (!expected.success) return false;
    const snapshot = this.state();
    if (snapshot.phase === "signed_out") {
      return sameLifecycleExpectation(expected.data, sessionExpectation(snapshot));
    }
    if (snapshot.phase === "signed_in") {
      return sameLifecycleExpectation(expected.data, sessionExpectation(snapshot));
    }
    if (snapshot.phase === "authenticating" && this.#authAttempt) {
      return sameLifecycleExpectation(
        expected.data,
        this.#authAttempt.attempt.expected
      );
    }
    return false;
  }

  #markProblemResult<Operation extends SessionOperationName>(
    operation: Operation,
    code:
      | "credential_mutation_uncertain"
      | "credential_store_unreadable"
      | "protocol_mismatch"
      | "session_probe_unavailable",
    problemOperation:
      | "authenticate"
      | "initialize"
      | "invalidate"
      | "reconcile"
      | "sign_out"
  ): { error: SessionOperationError<Operation>; ok: false } {
    this.#authority.markIndeterminate(createSessionProblem(code, problemOperation));
    return this.#errorResult(operation, code);
  }

  #errorResult<Operation extends SessionOperationName>(
    operation: Operation,
    code: SessionOperationErrorCode,
    retryAfterMs?: number
  ): { error: SessionOperationError<Operation>; ok: false } {
    return {
      error: createSessionOperationErrorOrUnknown(
        operation,
        code,
        this.state(),
        retryAfterMs
      ),
      ok: false,
    };
  }
}

function activeCredential(
  active: SecureSessionVaultActive
): SecureSessionActiveCredential {
  const { credentialVersion: _credentialVersion, ...credential } = active;
  return secureSessionActiveCredentialSchema.parse(credential);
}

function supersededAuthAttempts(
  attempt: AuthAttemptState | undefined
): AuthAttemptState[] | undefined {
  if (!attempt) return [];
  const candidates = [attempt, ...attempt.supersededAttempts];
  if (candidates.length > MAX_SUPERSEDED_AUTH_ATTEMPTS) return undefined;
  return [...new Set(candidates)];
}

function issuedCredentialsForAttempts(
  attempts: readonly AuthAttemptState[]
): SecureSessionActiveCredential[] {
  const unique: SecureSessionActiveCredential[] = [];
  for (const attempt of attempts) {
    const candidate = attempt.committingCredential;
    if (!candidate) continue;
    if (unique.some((current) => sameCredentialIdentity(current, candidate))) {
      continue;
    }
    unique.push(candidate);
  }
  return unique;
}

function sameCredentialIdentity(
  left: SecureSessionActiveCredential,
  right: SecureSessionActiveCredential
): boolean {
  return (
    left.token === right.token &&
    left.audience === right.audience &&
    left.sessionId === right.sessionId
  );
}

function credentialFromRemote(
  token: string,
  audience: string,
  remote: Omit<z.output<typeof issuedSessionSchema>, "token">
): SecureSessionActiveCredential {
  return secureSessionActiveCredentialSchema.parse({
    audience,
    email: remote.user.email,
    expiresAtEpochSeconds: remote.expires_at,
    sessionId: remote.session_id,
    token,
    userId: remote.user.id,
  });
}

async function remoteErrorForResponse(
  response: Response
): Promise<RemoteOperationError> {
  const retryAfter = response.headers.get("retry-after");
  const retryAfterMs =
    retryAfter && Number.isFinite(Number(retryAfter))
      ? Math.max(1, Math.trunc(Number(retryAfter) * 1_000))
      : undefined;

  const remoteCode = await readRemoteErrorCode(response);
  if (remoteCode === "invalid_verification_code") {
    return new RemoteOperationError("invalid_challenge");
  }
  if (remoteCode === "invalid_google_attempt") {
    return new RemoteOperationError("challenge_expired");
  }
  if (remoteCode === "disabled") {
    return new RemoteOperationError("account_disabled");
  }
  if (
    remoteCode === "auth_unavailable" ||
    remoteCode === "email_delivery_unavailable" ||
    remoteCode === "google_not_configured" ||
    remoteCode === "google_provider_unavailable"
  ) {
    return new RemoteOperationError("provider_unavailable", retryAfterMs);
  }
  if (
    remoteCode === "google_link_changed" ||
    remoteCode === "identity_conflict" ||
    remoteCode === "provider_already_linked"
  ) {
    return new RemoteOperationError("conflict");
  }

  if (response.status === 401) return new RemoteOperationError("unauthorized");
  if (response.status === 403) return new RemoteOperationError("account_disabled");
  if (response.status === 409) return new RemoteOperationError("conflict");
  if (response.status === 429) {
    return new RemoteOperationError("rate_limited", retryAfterMs);
  }
  if (response.status === 503) {
    return new RemoteOperationError("provider_unavailable", retryAfterMs);
  }
  return new RemoteOperationError("unknown");
}

async function readRemoteErrorCode(response: Response): Promise<string | undefined> {
  try {
    const body: unknown = await response.clone().json();
    if (
      typeof body === "object" &&
      body !== null &&
      "error" in body &&
      typeof body.error === "string" &&
      body.error.length <= 256
    ) {
      return body.error;
    }
  } catch {
    // Status-only classification remains available for non-JSON error bodies.
  }
  return undefined;
}

function hasUntrustedPendingAudience(
  vault: Extract<SecureSessionVaultSnapshot, { status: "readable" }>,
  trustedAudience: string
) {
  return vault.pendingRevocations.some(
    (pending) => pending.audience !== trustedAudience
  );
}

function pendingRevocationKey(pending: SecurePendingSessionRevocationRecord) {
  return JSON.stringify([pending.audience, pending.sessionId ?? null, pending.token]);
}

function issuedCredentialKey(credential: SecureSessionActiveCredential) {
  return JSON.stringify([credential.audience, credential.sessionId, credential.token]);
}

function electronSessionClientMetadata() {
  const clientPlatform =
    process.platform === "darwin"
      ? "macos"
      : process.platform === "win32"
        ? "windows"
        : process.platform === "linux"
          ? "linux"
          : "unknown";

  return {
    client_kind: "electron",
    client_platform: clientPlatform,
  } as const;
}

function lifecycleExpectationOrUndefined(
  snapshot: SessionLifecycleSnapshot
): SessionLifecycleExpectation | undefined {
  return snapshot.phase === "signed_in" || snapshot.phase === "signed_out"
    ? sessionExpectation(snapshot)
    : undefined;
}

function leaseExpectation(
  lease: MainProductCredentialLease
): SessionPresenceExpectation {
  return {
    authorityInstanceId: lease.authorityInstanceId,
    expectedAudience: lease.audience,
    expectedSessionId: lease.sessionId,
    generation: lease.generation,
  };
}

function sameLifecycleExpectation(
  left: SessionLifecycleExpectation,
  right: SessionLifecycleExpectation
) {
  if (
    left.authorityInstanceId !== right.authorityInstanceId ||
    left.generation !== right.generation ||
    left.expectedSessionId !== right.expectedSessionId
  ) {
    return false;
  }
  if (left.expectedSessionId === null || right.expectedSessionId === null) {
    return left.expectedSessionId === right.expectedSessionId;
  }
  return left.expectedAudience === right.expectedAudience;
}

function sameAuthAttempt(left: SessionAuthAttemptRef, right: SessionAuthAttemptRef) {
  return (
    left.attemptId === right.attemptId &&
    sameLifecycleExpectation(left.expected, right.expected)
  );
}

function normalizeTimeout(value: number | undefined, fallback: number) {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.max(1, Math.trunc(value))
    : fallback;
}

function increment(value: number) {
  if (!Number.isSafeInteger(value) || value >= Number.MAX_SAFE_INTEGER) {
    throw new Error("Session operation epoch is exhausted.");
  }
  return value + 1;
}
