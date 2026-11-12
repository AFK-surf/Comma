// The bearer session lifecycle (Electron's, and the phone apps'), run by the core: how a person signs in (an emailed
// code, Google through Main's window or Android's account chooser, Apple through the iPhone's sheet) and out, what the server says of the stored session at startup and on a retry, what happens when the
// server refuses a product request, and the revocation of credentials no longer wanted. It is the state machine Main
// ran (its session service) moved into the core: the same phases, attempts and their supersession (at most 32), the
// commit fence that orders every change of the credential store, the quarantine of a credential a sign-in no longer
// wants, and the bounded revocation drain (4 passes of 32). Its publishing, fencing and re-probes are the ones the web
// lifecycle has (lifecycle.ts); every wait is on the core's Clock (5 s per request).
//
// The bearer never reaches the core. Main keeps it: the host's `authFetch` sends an auth request through Main, which
// attaches the credential the request names by reference and takes any bearer out of the answer, keeping it and
// answering a reference instead (`credential`). The core changes Main's credential store by reference
// (`BearerSessionPorts.change`) and reads it without bearers (`vault`). Each snapshot it publishes goes to Main first
// (`gate`): Main opens or closes its gate on it (its `/v1` proxy, its native consumers) before any request or UI acts
// on that generation, and refuses a request made for another. A 401 Main sees closes Main's gate at once and comes
// here as a refusal of the lease. When the core restarts, it continues the authority Main's gate holds
// (`BearerSessionPorts.resumed`): a startup probe that finds the same session keeps the lease Main kept serving.
import { lazySchema } from "@comma/chat-contract";
import {
  sessionExpectation,
  sessionOperationErrorRule,
  sessionProductLease,
  type SessionAbsenceExpectation,
  type SessionAuthAttemptRef,
  type SessionLifecycleExpectation,
  type SessionOperationErrorCode,
  type SessionOperationName,
  type SessionOperationResult,
  type SessionProblem,
  type SignedInSessionSnapshot,
  type SignedOutSessionSnapshot,
} from "@comma/session-contract";
import { fromUtf8, HostError, utf8 } from "@comma/core-kernel";
import { Deferred, Effect, Result, Semaphore } from "effect";
import { z } from "zod";
import type { SessionEmailChallenge, SessionGoogleSignIn } from "../contract.ts";
import type {
  ApiResponse,
  AuthRequest,
  BearerCredential,
  BearerSessionPorts,
  BearerVault,
  CredentialRef,
  GoogleGrant,
  SessionLease,
} from "../host.ts";
import { MAX_KEPT_CREDENTIALS } from "../hosts/utility-protocol.ts";
import {
  type LifecycleAttempt,
  type LifecycleDeps,
  type ProblemCode,
  type ProblemOperation,
  type ReconcileReason,
  type ReconcileResult,
  SessionLifecycle,
} from "./lifecycle.ts";
import {
  googleLinkChallenge,
  sessionProjection,
  signedOutAnswer,
  type SessionProjection,
} from "./web-auth.ts";
import { AbuseError } from "./abuse.ts";
import type { AuthResponse } from "./web-auth.ts";

const REQUEST_TIMEOUT_MS = 5_000;
const MAX_REVOCATION_DRAIN_PASSES = 4;
const MAX_REVOCATION_RECORDS_PER_PASS = 32;
const MAX_REVOCATION_RECORDS_PER_DRAIN =
  MAX_REVOCATION_DRAIN_PASSES * MAX_REVOCATION_RECORDS_PER_PASS;
const MAX_SUPERSEDED_AUTH_ATTEMPTS = 32;

/** A session answer that issued a credential: Main kept the bearer and answers its reference. */
const issuedSession = lazySchema(() =>
  sessionProjection.extend({
    credential: z.string().min(1).max(256),
  })
);
/** A probe's answer: it must never carry a credential (a reflected bearer is a protocol mismatch). */
const currentSession = lazySchema(() =>
  sessionProjection.extend({ credential: z.never().optional() })
);
const emailChallenge = lazySchema(() =>
  z.object({
    challenge_id: z.string().min(1).max(256),
    code: z.string().min(1).max(32).optional(),
    expires_in: z.number().int().nonnegative().optional(),
    resend_after: z.number().int().nonnegative().optional(),
  })
);
const googleAttempt = lazySchema(() =>
  z.object({
    attempt_id: z.string().min(1).max(256),
    client_id: z.string().min(1).max(2_048),
    nonce: z.string().min(1).max(2_048),
    platform: z.enum(["android", "electron", "ios"]),
  })
);
const googleResult = lazySchema(() => z.union([issuedSession, googleLinkChallenge]));
const appleAttempt = lazySchema(() =>
  z.object({
    attempt_id: z.string().min(1).max(256),
    client_id: z.string().min(1).max(2_048),
    nonce: z.string().min(1).max(2_048),
  })
);

/** Why a request did not give the answer wanted, as the session contract names it. */
class RemoteError {
  constructor(
    readonly code: SessionOperationErrorCode | "unauthorized",
    readonly retryAfterMs?: number
  ) {}
}

type ElectronAttempt = LifecycleAttempt & {
  kind: "email" | "google" | "apple";
  /** Retired (replaced, cancelled, signed out): its answers are refused. */
  isRetired: boolean;
  /** Done once it is retired: its Google window closes. */
  retired: Deferred.Deferred<void>;
  /** Whether the credential its sign-in was issued, if one, has been committed or quarantined. */
  cleanupSettled: boolean;
  committing?: CredentialRef;
  inFlight?: Deferred.Deferred<void>;
  supersededAttempts: ElectronAttempt[];
};

type SignInOperation =
  | "verify_email_login"
  | "sign_in_with_google"
  | "verify_google_link"
  | "sign_in_with_apple"
  | "verify_apple_link";

export class ElectronSessionLifecycle extends SessionLifecycle<ElectronAttempt> {
  readonly origin: string;
  readonly #ports: BearerSessionPorts;
  readonly #authFetch: (request: AuthRequest) => Effect.Effect<ApiResponse, HostError>;
  /** Orders every change of the credential store and every publication that follows one. */
  readonly #fence = Semaphore.makeUnsafe(1);
  #startupReconcileAvailable = true;
  /** Credentials issued to a sign-in that are neither committed nor queued for revocation yet. */
  readonly #unresolved = new Set<CredentialRef>();
  /** The active credential the signed-in snapshot was opened with (its reference in Main's store). */
  #activeRef: CredentialRef | null = null;
  /** The credentials of the accounts kept signed in besides the one in use, as the store last said. */
  #keptRefs: BearerCredential[] = [];
  #drain: Deferred.Deferred<void> | null = null;
  /** What Main was last told (`gate`): told again only when it changes. */
  #told: string | null = null;
  #quiet = true;

  constructor(deps: LifecycleDeps) {
    const kind = deps.host.bearerSession?.clientKind;
    super(
      deps,
      kind === "android"
        ? "android_keystore"
        : kind === "ios"
          ? "swiftui_keychain"
          : "electron_main"
    );
    const { host } = deps;
    if (!host.authFetch || !host.bearerSession)
      throw new Error(
        "the Electron session lifecycle needs the host's authFetch and bearerSession"
      );
    this.#authFetch = host.authFetch.bind(host);
    this.kept = [];
    this.#ports = host.bearerSession;
    this.origin = this.#ports.apiOrigin;
    if (this.#ports.resumed) this.resumeFrom(this.#ports.resumed);
    this.sync();
    // Main's gate already holds where this authority is: the first thing told is the first change.
    this.#told = this.#gateState();
    this.#quiet = false;
  }

  /** Finds out what the stored credential is worth (the core started), then revokes what waits. */
  start(): void {
    this.fork(
      this.reconcile({ reason: "startup" }).pipe(
        Effect.tap((result) =>
          result.ok ? this.retryPendingRevocations() : Effect.void
        )
      )
    );
  }

  protected audience(): string {
    return this.origin;
  }

  /** Main is told first: its gate moves before the account, the lease or any UI acts on the change. */
  protected override sync(): void {
    if (!this.#quiet) {
      const state = this.#gateState();
      if (state !== this.#told) {
        this.#told = state;
        this.#ports.gate(this.current, this.#lease());
      }
    }
    super.sync();
  }

  #lease(): SessionLease | null {
    return this.productOpen() ? (sessionProductLease(this.current) ?? null) : null;
  }

  #gateState(): string {
    return JSON.stringify([this.current.revision, this.#lease()]);
  }

  // --- Reconciling -----------------------------------------------------------------------------------------------

  reconcile(input: {
    expected?: SessionLifecycleExpectation;
    reason: ReconcileReason;
  }): Effect.Effect<ReconcileResult> {
    const operation = "reconcile" as const;
    return Effect.suspend(() => {
      const current = this.current;
      const startup =
        input.reason === "startup" &&
        input.expected === undefined &&
        this.#startupReconcileAvailable;
      const indeterminateRetry =
        input.reason === "manual_retry" &&
        input.expected === undefined &&
        current.phase === "indeterminate";
      if (!startup && !indeterminateRetry && !this.#matches(input.expected))
        return Effect.succeed(this.failure(operation, "conflict"));
      if (current.phase === "authenticating")
        return Effect.succeed(this.failure(operation, "conflict"));
      this.#startupReconcileAvailable = false;
      const epoch = this.nextEpoch();
      return this.#reconcile(epoch);
    });
  }

  /** `session.recover`: the person asked to try again. */
  override recover(): Effect.Effect<void> {
    return Effect.suspend(() => {
      const current = this.current;
      if (current.phase === "initializing" && this.#startupReconcileAvailable)
        return Effect.asVoid(this.reconcile({ reason: "startup" }));
      const expected = this.expectation();
      return Effect.asVoid(
        this.reconcile(
          expected ? { expected, reason: "manual_retry" } : { reason: "manual_retry" }
        )
      );
    });
  }

  #reconcile(epoch: number): Effect.Effect<ReconcileResult> {
    const operation = "reconcile" as const;
    const stale = () => !this.isCurrentEpoch(epoch) || this.closed;
    return Effect.gen({ self: this }, function* () {
      if (this.#unresolved.size > 0 && !(yield* this.#retryUnresolved()))
        return yield* this.#fenced(
          Effect.sync(() =>
            stale()
              ? this.failure(operation, "conflict")
              : this.#problem(operation, "credential_mutation_uncertain", "reconcile")
          )
        );
      const read = yield* Effect.result(this.#ports.vault);
      if (Result.isFailure(read))
        return yield* this.#fenced(
          Effect.sync(() =>
            stale()
              ? this.failure(operation, "conflict")
              : this.#problem(operation, "credential_store_unreadable", "reconcile")
          )
        );
      let vault = read.success;
      if (vault.status === "indeterminate") {
        const problem = vault.problem;
        return yield* this.#fenced(
          Effect.sync(() => {
            if (stale()) return this.failure(operation, "conflict");
            this.#publishProblem(problem);
            return this.failureOrUnknown(operation, problem.code);
          })
        );
      }
      if (
        (vault.active && vault.active.audience !== this.origin) ||
        vault.pending.some((pending) => pending.audience !== this.origin)
      ) {
        // A configured backend change retires only credentials for other origins. Local removal does not claim
        // remote revocation or contact the old origin.
        const cleaned = yield* this.#fenced(
          Effect.gen({ self: this }, function* () {
            if (stale()) return this.failure(operation, "conflict");
            this.#activeRef = null;
            this.revoke();
            const changed = yield* Effect.result(
              this.#ports.change({ kind: "retainAudience" })
            );
            if (Result.isFailure(changed))
              return stale()
                ? this.failure(operation, "conflict")
                : this.#problem(
                    operation,
                    "credential_mutation_uncertain",
                    "reconcile"
                  );
            if (!isVault(changed.success) || stale())
              return this.failure(operation, "conflict");
            return changed.success;
          })
        );
        if ("ok" in cleaned) return cleaned;
        if (cleaned.status !== "readable") {
          this.#publishProblem(cleaned.problem);
          return this.failureOrUnknown(operation, cleaned.problem.code);
        }
        vault = cleaned;
      }
      const active = vault.active;
      if (!active) {
        const empty = vault;
        return yield* this.#fenced(
          Effect.sync(() => {
            if (stale()) return this.failure(operation, "conflict");
            this.#took(empty);
            this.#activeRef = null;
            return { ok: true as const, value: this.publishSignedOut("no_session") };
          })
        );
      }
      // The host already kept this session after a successful sign-in. Restore it before the network check.
      // Server requests still carry its credential and the server can reject it. A temporary outage does not end it.
      yield* this.#fenced(
        Effect.sync(() => {
          // A host that already closed a lease must wait for the server before it can reopen it.
          const resumed = this.#ports.resumed;
          if (
            stale() ||
            this.current.phase !== "initializing" ||
            (resumed && resumed.generation > 0 && resumed.sessionId === null)
          )
            return;
          this.#took(vault);
          this.#activeRef = active.ref;
          this.publishSignedIn({
            expires_at: active.expiresAtEpochSeconds,
            session_id: active.sessionId,
            user: { id: active.userId, email: active.email },
          });
        })
      );
      if (stale()) return this.failure(operation, "conflict");
      const probe = yield* this.#probe(active.ref);
      return yield* this.#fenced(
        Effect.gen({ self: this }, function* () {
          if (stale()) return this.failure(operation, "conflict");
          if (probe.kind === "error") {
            if (probe.code === "session_probe_unavailable" && this.productOpen()) {
              this.scheduleBackgroundReconcile();
              return this.failure(operation, probe.code);
            }
            return this.#problem(operation, probe.code, "reconcile");
          }
          if (probe.kind === "unauthorized") {
            const removed = yield* Effect.result(
              this.#ports.change({ kind: "invalidate", active: active.ref })
            );
            if (stale()) return this.failure(operation, "conflict");
            if (Result.isFailure(removed))
              return this.#problem(
                operation,
                "credential_mutation_uncertain",
                "reconcile"
              );
            this.#took(removed.success);
            this.#activeRef = null;
            return { ok: true as const, value: this.publishSignedOut("unauthorized") };
          }
          const projection = probe.value;
          const adopted = yield* Effect.result(
            this.#ports.change({
              kind: "adopt",
              active: active.ref,
              identity: {
                email: projection.user.email,
                expiresAtEpochSeconds: projection.expires_at,
                sessionId: projection.session_id,
                userId: projection.user.id,
              },
            })
          );
          if (stale()) return this.failure(operation, "conflict");
          if (Result.isFailure(adopted))
            return this.#problem(
              operation,
              "credential_mutation_uncertain",
              "reconcile"
            );
          if (!isVault(adopted.success)) return this.failure(operation, "conflict");
          this.#took(adopted.success);
          this.#activeRef = active.ref;
          const snapshot = this.publishSignedIn(projection);
          this.fork(this.retryPendingRevocations());
          return { ok: true as const, value: snapshot };
        })
      );
    });
  }

  #probe(
    ref: CredentialRef
  ): Effect.Effect<
    | { kind: "ok"; value: SessionProjection }
    | { kind: "unauthorized" }
    | { kind: "error"; code: "protocol_mismatch" | "session_probe_unavailable" }
  > {
    return this.#request("GET", "/v1/comma/auth/session", currentSession, {
      credential: ref,
    }).pipe(
      Effect.map((value) => ({ kind: "ok" as const, value })),
      Effect.catch((error: RemoteError) =>
        Effect.succeed(
          error.code === "unauthorized"
            ? { kind: "unauthorized" as const }
            : {
                kind: "error" as const,
                code:
                  error.code === "protocol_mismatch"
                    ? ("protocol_mismatch" as const)
                    : ("session_probe_unavailable" as const),
              }
        )
      )
    );
  }

  // --- Signing in ------------------------------------------------------------------------------------------------

  protected requestEmailChallenge(input: {
    email: string;
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<
    SessionOperationResult<SessionEmailChallenge, "request_email_login">
  > {
    const operation = "request_email_login" as const;
    type Out = SessionOperationResult<SessionEmailChallenge, "request_email_login">;
    return this.#withSignals((signals): Effect.Effect<Out> => {
      const email = input.email.trim().toLowerCase();
      const previous = this.attempt;
      const sameEmail = previous?.kind === "email" && previous.email === email;
      if (sameEmail && previous.inFlight)
        return Effect.succeed(this.failure(operation, "conflict"));
      const resending = Boolean(
        sameEmail && previous.challengeId && this.#matches(input.expected)
      );
      const started =
        resending && previous
          ? { attempt: previous, wake: Effect.void }
          : this.#startAttempt("email", input.expected, signals.retired);
      if (!started) return Effect.succeed(this.failure(operation, "conflict"));
      const { attempt, wake } = started;
      attempt.email = email;
      const finish = this.#begin(attempt, signals.inFlight);
      if (!finish) return Effect.succeed(this.failure(operation, "conflict"));
      return Effect.gen({ self: this }, function* () {
        yield* wake;
        const answer = yield* Effect.result(
          this.#request("POST", "/v1/comma/auth/email/login", emailChallenge, {
            body: { email, platform: this.#ports.clientKind ?? "electron" },
            protect: true,
          })
        );
        if (Result.isFailure(answer))
          return yield* this.#settleAuthError(operation, attempt, answer.failure, {
            retainRetryableAttempt: resending,
          });
        if (!this.#isCurrent(attempt)) return this.failure(operation, "cancelled");
        const challenge = answer.success;
        attempt.challengeId = challenge.challenge_id;
        this.sync();
        return {
          ok: true as const,
          value: {
            attempt: attempt.attempt,
            challengeId: challenge.challenge_id,
            ...(challenge.expires_in !== undefined
              ? { expiresInSeconds: challenge.expires_in }
              : {}),
            ...(challenge.resend_after !== undefined
              ? { resendAfterSeconds: challenge.resend_after }
              : {}),
          },
        };
      }).pipe(Effect.ensuring(finish));
    });
  }

  verifyEmailLogin(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Effect.Effect<
    SessionOperationResult<SignedInSessionSnapshot, "verify_email_login">
  > {
    return this.#verify(
      "verify_email_login",
      "email",
      "/v1/comma/auth/email/verify",
      input
    );
  }

  verifyGoogleLink(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Effect.Effect<
    SessionOperationResult<SignedInSessionSnapshot, "verify_google_link">
  > {
    return this.#verify(
      "verify_google_link",
      "google",
      "/v1/comma/auth/google/link/verify",
      input
    );
  }

  verifyAppleLink(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Effect.Effect<
    SessionOperationResult<SignedInSessionSnapshot, "verify_apple_link">
  > {
    return this.#verify(
      "verify_apple_link",
      "apple",
      "/v1/comma/auth/apple/link/verify",
      input
    );
  }

  #verify<
    Operation extends "verify_email_login" | "verify_google_link" | "verify_apple_link",
  >(
    operation: Operation,
    kind: ElectronAttempt["kind"],
    path: string,
    input: { attempt: SessionAuthAttemptRef; challengeId: string; code: string }
  ): Effect.Effect<SessionOperationResult<SignedInSessionSnapshot, Operation>> {
    type Out = SessionOperationResult<SignedInSessionSnapshot, Operation>;
    return this.#withSignals((signals): Effect.Effect<Out> => {
      const attempt = this.#matchingAttempt(input, kind);
      if (!attempt) return Effect.succeed(this.failureOrUnknown(operation, "conflict"));
      const finish = this.#begin(attempt, signals.inFlight);
      if (!finish) return Effect.succeed(this.failureOrUnknown(operation, "conflict"));
      return Effect.gen({ self: this }, function* () {
        const issued = yield* Effect.result(
          this.#request("POST", path, issuedSession, {
            body: {
              challenge_id: input.challengeId,
              code: input.code,
              ...this.#clientMetadata(),
            },
          })
        );
        if (Result.isFailure(issued))
          return yield* this.#settleAuthError(operation, attempt, issued.failure);
        return yield* this.#commitIssued(operation, attempt, issued.success);
      }).pipe(Effect.ensuring(finish));
    });
  }

  /** Google through Main's window: the server's attempt, the window, then the code exchanged for a session. */
  signInWithGoogle(input: {
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<
    SessionOperationResult<SessionGoogleSignIn, "sign_in_with_google">
  > {
    const operation = "sign_in_with_google" as const;
    type Out = SessionOperationResult<SessionGoogleSignIn, "sign_in_with_google">;
    const google = this.#ports.google;
    if (!google) return Effect.succeed(this.failure(operation, "unsupported"));
    const googleDone = this.#ports.googleDone;
    return this.#withSignals((signals): Effect.Effect<Out> => {
      const started = this.#startAttempt("google", input.expected, signals.retired);
      if (!started) return Effect.succeed(this.failure(operation, "conflict"));
      const { attempt, wake } = started;
      const finish = this.#begin(attempt, signals.inFlight);
      if (!finish) return Effect.succeed(this.failure(operation, "conflict"));
      let grant: GoogleGrant | undefined;
      const done = (ok: boolean) =>
        grant && googleDone ? googleDone(grant.grant, ok) : Effect.void;
      return Effect.gen({ self: this }, function* () {
        yield* wake;
        const prepared = yield* Effect.result(
          this.#request("POST", "/v1/comma/auth/google/attempt", googleAttempt, {
            body: { platform: this.#ports.clientKind ?? "electron" },
          })
        );
        if (Result.isFailure(prepared))
          return yield* this.#settleAuthError(operation, attempt, prepared.failure, {
            retainRetryableAttempt: false,
          });
        const remote = prepared.success;
        // The window closes when the attempt is retired (replaced, cancelled, signed out).
        const window = yield* Effect.result(
          Effect.raceFirst(
            google({ clientId: remote.client_id, nonce: remote.nonce }).pipe(
              Effect.mapError(
                (error) =>
                  new RemoteError(
                    error.message === "cancelled" ? "cancelled" : "unknown"
                  )
              )
            ),
            Deferred.await(attempt.retired).pipe(
              Effect.andThen(Effect.fail(new RemoteError("cancelled")))
            )
          )
        );
        if (Result.isFailure(window))
          return yield* this.#settleAuthError(operation, attempt, window.failure, {
            retainRetryableAttempt: false,
          });
        grant = window.success;
        const result = yield* Effect.result(
          this.#request("POST", "/v1/comma/auth/google", googleResult, {
            protect: true,
            body: {
              attempt_id: remote.attempt_id,
              nonce: remote.nonce,
              ...("idToken" in grant
                ? { credential: grant.idToken }
                : {
                    authorization_code: grant.authorizationCode,
                    code_verifier: grant.codeVerifier,
                    redirect_uri: grant.redirectUri,
                  }),
              ...this.#clientMetadata(),
            },
          })
        );
        if (Result.isFailure(result)) {
          yield* done(false);
          return yield* this.#settleAuthError(operation, attempt, result.failure, {
            retainRetryableAttempt: false,
          });
        }
        const signedIn = yield* this.#providerSignedIn(
          operation,
          attempt,
          result.success
        );
        yield* done(signedIn.ok);
        return signedIn;
      }).pipe(Effect.ensuring(finish));
    });
  }

  /** Apple through the iPhone's sheet: the server's attempt, the sheet, then its identity token exchanged. */
  signInWithApple(input: {
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<SessionOperationResult<SessionGoogleSignIn, "sign_in_with_apple">> {
    const operation = "sign_in_with_apple" as const;
    type Out = SessionOperationResult<SessionGoogleSignIn, "sign_in_with_apple">;
    const apple = this.#ports.apple;
    if (!apple) return Effect.succeed(this.failure(operation, "unsupported"));
    return this.#withSignals((signals): Effect.Effect<Out> => {
      const started = this.#startAttempt("apple", input.expected, signals.retired);
      if (!started) return Effect.succeed(this.failure(operation, "conflict"));
      const { attempt, wake } = started;
      const finish = this.#begin(attempt, signals.inFlight);
      if (!finish) return Effect.succeed(this.failure(operation, "conflict"));
      return Effect.gen({ self: this }, function* () {
        yield* wake;
        const prepared = yield* Effect.result(
          this.#request("POST", "/v1/comma/auth/apple/attempt", appleAttempt, {
            body: {},
          })
        );
        if (Result.isFailure(prepared))
          return yield* this.#settleAuthError(operation, attempt, prepared.failure, {
            retainRetryableAttempt: false,
          });
        const remote = prepared.success;
        // The sheet closes when the attempt is retired (replaced, cancelled, signed out).
        const sheet = yield* Effect.result(
          Effect.raceFirst(
            apple({ clientId: remote.client_id, nonce: remote.nonce }).pipe(
              Effect.mapError(() => new RemoteError("cancelled"))
            ),
            Deferred.await(attempt.retired).pipe(
              Effect.andThen(Effect.fail(new RemoteError("cancelled")))
            )
          )
        );
        if (Result.isFailure(sheet))
          return yield* this.#settleAuthError(operation, attempt, sheet.failure, {
            retainRetryableAttempt: false,
          });
        const result = yield* Effect.result(
          this.#request("POST", "/v1/comma/auth/apple", googleResult, {
            protect: true,
            body: {
              attempt_id: remote.attempt_id,
              identity_token: sheet.success.identityToken,
              ...this.#clientMetadata(),
            },
          })
        );
        if (Result.isFailure(result))
          return yield* this.#settleAuthError(operation, attempt, result.failure, {
            retainRetryableAttempt: false,
          });
        return yield* this.#providerSignedIn(operation, attempt, result.success);
      }).pipe(Effect.ensuring(finish));
    });
  }

  /** A provider's answer: a session to commit, or a code that links the provider's account to an existing one. */
  #providerSignedIn<Operation extends "sign_in_with_google" | "sign_in_with_apple">(
    operation: Operation,
    attempt: ElectronAttempt,
    value: z.output<typeof googleResult>
  ): Effect.Effect<SessionOperationResult<SessionGoogleSignIn, Operation>> {
    return Effect.gen({ self: this }, function* () {
      if ("status" in value) {
        attempt.challengeId = value.challenge_id;
        attempt.email = value.email;
        this.sync();
        return {
          ok: true as const,
          value: {
            attempt: attempt.attempt,
            challengeId: value.challenge_id,
            email: value.email,
            status: "otp_required" as const,
          },
        };
      }
      const committed = yield* this.#commitIssued(operation, attempt, value);
      if (!committed.ok) return committed;
      return {
        ok: true as const,
        value: { snapshot: committed.value, status: "signed_in" as const },
      };
    });
  }

  cancelAuthAttempt(input: {
    attempt: SessionAuthAttemptRef;
  }): Effect.Effect<
    SessionOperationResult<SignedOutSessionSnapshot, "cancel_auth_attempt">
  > {
    return Effect.suspend(() => {
      const attempt = this.attempt;
      if (!attempt || !sameAuthAttempt(attempt.attempt, input.attempt))
        return Effect.succeed(this.failure("cancel_auth_attempt", "conflict"));
      return this.#signOut("cancel_auth_attempt", "no_session");
    });
  }

  signOut(input: {
    expected: SessionLifecycleExpectation;
  }): Effect.Effect<SessionOperationResult<SignedOutSessionSnapshot, "sign_out">> {
    return Effect.suspend(() => {
      const current = this.current;
      if (!this.#matches(input.expected))
        return Effect.succeed(this.failure("sign_out", "conflict"));
      if (current.phase === "signed_out")
        return Effect.succeed({ ok: true as const, value: current });
      if (current.phase !== "signed_in" && current.phase !== "authenticating")
        return Effect.succeed(this.failure("sign_out", "conflict"));
      return this.#signOut("sign_out", "user_signed_out");
    });
  }

  /** Signing out (or giving up a sign-in): the gate closes now, the credential is queued for revocation. */
  #signOut<Operation extends "cancel_auth_attempt" | "sign_out">(
    operation: Operation,
    reason: "no_session" | "user_signed_out"
  ): Effect.Effect<SessionOperationResult<SignedOutSessionSnapshot, Operation>> {
    const retiring = this.attempt;
    const retired = retiring ? [retiring, ...retiring.supersededAttempts] : [];
    const inFlight = retired.flatMap((candidate) =>
      candidate.inFlight ? [candidate.inFlight] : []
    );
    const { epoch, wake } = this.#retireAttempt();
    this.#activeRef = null;
    this.publishTransient("signing_out");
    const stale = () => !this.isCurrentEpoch(epoch) || this.closed;
    return Effect.gen({ self: this }, function* () {
      yield* wake;
      yield* Effect.forEach(inFlight, (deferred) => Deferred.await(deferred), {
        discard: true,
      });
      return yield* this.#fenced(
        Effect.gen({ self: this }, function* () {
          if (stale()) return this.failureOrUnknown(operation, "conflict");
          if (!(yield* this.#retryUnsettled(retired)))
            return this.#problem(
              operation,
              "credential_mutation_uncertain",
              "authenticate"
            );
          const changed = yield* Effect.result(this.#ports.change({ kind: "signOut" }));
          if (stale()) return this.failureOrUnknown(operation, "conflict");
          if (Result.isFailure(changed))
            return this.#problem(
              operation,
              "credential_mutation_uncertain",
              "sign_out"
            );
          this.#took(changed.success);
          const signedOut = this.publishSignedOut(reason);
          this.fork(this.retryPendingRevocations());
          return { ok: true as const, value: signedOut };
        })
      );
    });
  }

  // --- Accounts kept signed in -----------------------------------------------------------------------------------

  /**
   * Another account is to be added: the one in use is set aside, still signed in (kept in the store), and the session
   * is signed out for the next sign-in. At most `MAX_KEPT_CREDENTIALS` are kept.
   */
  addAccount(input: {
    expected: SessionLifecycleExpectation;
  }): Effect.Effect<SessionOperationResult<SignedOutSessionSnapshot, "add_account">> {
    const operation = "add_account" as const;
    return Effect.suspend(() => {
      if (
        !this.#matches(input.expected) ||
        this.current.phase !== "signed_in" ||
        this.#keptRefs.length >= MAX_KEPT_CREDENTIALS
      )
        return Effect.succeed(this.failure(operation, "conflict"));
      const epoch = this.nextEpoch();
      const stale = () => !this.isCurrentEpoch(epoch) || this.closed;
      return this.#fenced(
        Effect.gen({ self: this }, function* () {
          if (stale()) return this.failure(operation, "conflict");
          const changed = yield* Effect.result(this.#ports.change({ kind: "keep" }));
          if (stale()) return this.failure(operation, "conflict");
          if (Result.isFailure(changed))
            return this.#problem(
              operation,
              "credential_mutation_uncertain",
              "reconcile"
            );
          if (!isVault(changed.success) || changed.success.status !== "readable")
            return this.failure(operation, "conflict");
          this.#took(changed.success);
          this.#activeRef = null;
          return { ok: true as const, value: this.publishSignedOut("no_session") };
        })
      );
    });
  }

  /**
   * Makes a kept account the one in use, without signing in again: the store swaps it with the one in use (kept in
   * turn), the session is shown signed in as its stored identity at once, and the server confirms it after (as a
   * startup does). A sign-in under way is given up.
   */
  switchAccount(input: {
    userId: string;
  }): Effect.Effect<SessionOperationResult<SignedInSessionSnapshot, "switch_account">> {
    const operation = "switch_account" as const;
    return Effect.suspend(() => {
      const phase = this.current.phase;
      if (
        (phase !== "signed_in" &&
          phase !== "signed_out" &&
          phase !== "authenticating") ||
        !this.#keptRefs.some((kept) => kept.userId === input.userId)
      )
        return Effect.succeed(this.failure(operation, "conflict"));
      const retiring = this.attempt;
      const retired = retiring ? [retiring, ...retiring.supersededAttempts] : [];
      const inFlight = retired.flatMap((candidate) =>
        candidate.inFlight ? [candidate.inFlight] : []
      );
      const { epoch, wake } = this.#retireAttempt();
      const stale = () => !this.isCurrentEpoch(epoch) || this.closed;
      return Effect.gen({ self: this }, function* () {
        yield* wake;
        yield* Effect.forEach(inFlight, (deferred) => Deferred.await(deferred), {
          discard: true,
        });
        const switched = yield* this.#fenced(
          Effect.gen({ self: this }, function* () {
            if (stale()) return this.failure(operation, "conflict");
            if (!(yield* this.#retryUnsettled(retired)))
              return this.#problem(
                operation,
                "credential_mutation_uncertain",
                "authenticate"
              );
            const kept = this.#keptRefs.find(
              (candidate) => candidate.userId === input.userId
            );
            if (!kept) return this.failure(operation, "conflict");
            const changed = yield* Effect.result(
              this.#ports.change({ kind: "activate", kept: kept.ref })
            );
            if (stale()) return this.failure(operation, "conflict");
            if (Result.isFailure(changed))
              return this.#problem(
                operation,
                "credential_mutation_uncertain",
                "reconcile"
              );
            const vault = changed.success;
            if (!isVault(vault) || vault.status !== "readable" || !vault.active)
              return this.failure(operation, "conflict");
            const active = vault.active;
            this.#took(vault);
            this.#activeRef = active.ref;
            const snapshot = this.publishSignedIn({
              expires_at: active.expiresAtEpochSeconds,
              session_id: active.sessionId,
              user: { id: active.userId, email: active.email },
            });
            return { ok: true as const, value: snapshot };
          })
        );
        // The server confirms the session (or refuses it: signed out, the other accounts still kept).
        if (switched.ok) this.fork(this.#reconcile(this.nextEpoch()));
        // A sign-in given up for a switch that did not happen: back at the sign-in.
        else
          yield* this.#fenced(
            Effect.sync(() => {
              if (!stale() && this.current.phase === "authenticating" && !this.attempt)
                this.publishSignedOut("no_session");
            })
          );
        return switched;
      });
    });
  }

  /** Signs a kept account out of this device: its credential is queued for revocation (and revoked). */
  signOutAccount(input: {
    userId: string;
  }): Effect.Effect<SessionOperationResult<null, "sign_out_account">> {
    const operation = "sign_out_account" as const;
    return this.#fenced(
      Effect.gen({ self: this }, function* () {
        if (this.closed) return this.failure(operation, "conflict");
        const kept = this.#keptRefs.find(
          (candidate) => candidate.userId === input.userId
        );
        if (!kept) return this.failure(operation, "conflict");
        const changed = yield* Effect.result(
          this.#ports.change({ kind: "forget", kept: kept.ref })
        );
        if (this.closed) return this.failure(operation, "conflict");
        if (Result.isFailure(changed))
          return this.failureOrUnknown(operation, "credential_mutation_uncertain");
        if (!isVault(changed.success) || changed.success.status !== "readable")
          return this.failure(operation, "conflict");
        this.#keep(changed.success);
        this.publishCleanup(changed.success.cleanup);
        this.sync();
        this.fork(this.retryPendingRevocations());
        return { ok: true as const, value: null };
      })
    );
  }

  // --- A product request refused ---------------------------------------------------------------------------------

  /** The server (or Main) answered 401 to a product request made with `lease`: the session is invalidated. */
  productUnauthorized(lease: SessionLease): void {
    const current = this.current;
    if (
      current.phase !== "signed_in" ||
      !this.productOpen() ||
      this.session.lease() !== lease
    )
      return;
    const ref = this.#activeRef;
    this.#activeRef = null;
    this.publishTransient("invalidating");
    const epoch = this.nextEpoch();
    const stale = () => !this.isCurrentEpoch(epoch) || this.closed;
    this.fork(
      this.#fenced(
        Effect.gen({ self: this }, function* () {
          if (stale()) return;
          if (ref === null) {
            this.publishIndeterminate("credential_mutation_uncertain", "invalidate");
            return;
          }
          const removed = yield* Effect.result(
            this.#ports.change({ kind: "invalidate", active: ref })
          );
          if (stale()) return;
          if (Result.isFailure(removed) || !isVault(removed.success)) {
            this.publishIndeterminate("credential_mutation_uncertain", "invalidate");
            return;
          }
          this.#took(removed.success);
          this.publishSignedOut("unauthorized");
        })
      )
    );
  }

  /** The server answered 409 (another session) to a product request made with `lease`. */
  productSessionChanged(lease: SessionLease): void {
    const current = this.current;
    if (current.phase !== "signed_in" || this.session.lease() !== lease) return;
    this.peerReconcile(sessionExpectation(current));
  }

  // --- Revocation ------------------------------------------------------------------------------------------------

  /** Revokes the queued credentials at the server, at most 4 passes of 32; one drain at a time. */
  retryPendingRevocations(): Effect.Effect<void> {
    return Deferred.make<void>().pipe(
      Effect.flatMap((drain) => {
        const running = this.#drain;
        if (running) return Deferred.await(running);
        this.#drain = drain;
        return this.#runDrain().pipe(
          Effect.ensuring(
            Effect.suspend(() => {
              if (this.#drain === drain) this.#drain = null;
              return Deferred.succeed(drain, undefined);
            })
          )
        );
      })
    );
  }

  #runDrain(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const attempted = new Set<CredentialRef>();
      for (
        let pass = 0;
        pass < MAX_REVOCATION_DRAIN_PASSES &&
        attempted.size < MAX_REVOCATION_RECORDS_PER_DRAIN;
        pass += 1
      ) {
        if (this.closed) return;
        const read = yield* Effect.result(this.#ports.vault);
        if (Result.isFailure(read)) return;
        const vault = read.success;
        const current = this.current;
        if (
          vault.status !== "readable" ||
          vault.pending.some((pending) => pending.audience !== this.origin) ||
          (current.phase === "indeterminate" &&
            current.problem.code === "protocol_mismatch")
        )
          return;
        const remaining = MAX_REVOCATION_RECORDS_PER_DRAIN - attempted.size;
        const pending = vault.pending
          .filter((record) => !attempted.has(record.ref))
          .slice(0, Math.min(MAX_REVOCATION_RECORDS_PER_PASS, remaining));
        if (pending.length === 0) break;
        for (const record of pending) {
          attempted.add(record.ref);
          if (yield* this.#revokeRemotely(record.ref))
            // A failed write keeps the record queued; the other records go on.
            yield* Effect.ignore(
              this.#ports.change({ kind: "revoked", pending: record.ref })
            );
        }
      }
      yield* this.#fenced(
        Effect.gen({ self: this }, function* () {
          if (this.closed) return;
          const read = yield* Effect.result(this.#ports.vault);
          if (Result.isSuccess(read) && read.success.status === "readable") {
            this.#keep(read.success);
            this.publishCleanup(read.success.cleanup);
          }
        })
      );
    });
  }

  /** Logs the credential out at the server: true once the server no longer knows it (it answered, or 401). */
  #revokeRemotely(ref: CredentialRef): Effect.Effect<boolean> {
    return this.#request("POST", "/v1/comma/auth/logout", signedOutAnswer, {
      body: {},
      credential: ref,
    }).pipe(
      Effect.as(true),
      Effect.catch((error: RemoteError) =>
        Effect.succeed(error.code === "unauthorized")
      )
    );
  }

  // --- Committing an issued credential ---------------------------------------------------------------------------

  #commitIssued<Operation extends SignInOperation>(
    operation: Operation,
    attempt: ElectronAttempt,
    issued: z.output<typeof issuedSession>
  ): Effect.Effect<SessionOperationResult<SignedInSessionSnapshot, Operation>> {
    type Out = SessionOperationResult<SignedInSessionSnapshot, Operation>;
    const ref = issued.credential;
    return Effect.gen({ self: this }, function* () {
      attempt.committing = ref;
      attempt.cleanupSettled = false;
      this.#unresolved.add(ref);
      yield* Effect.forEach(
        attempt.supersededAttempts.flatMap((superseded) =>
          superseded.inFlight ? [superseded.inFlight] : []
        ),
        (deferred) => Deferred.await(deferred),
        { discard: true }
      );
      const supersede = [
        ...new Set(
          attempt.supersededAttempts.flatMap((superseded) =>
            superseded.committing ? [superseded.committing] : []
          )
        ),
      ];
      const settled = yield* this.#fenced(
        Effect.gen({ self: this }, function* () {
          const cancelled = Effect.gen({ self: this }, function* () {
            const queued = yield* this.#quarantine(ref);
            attempt.cleanupSettled = queued;
            return { kind: "cancelled" as const, needsRemoteCleanup: !queued };
          });
          if (!this.#isCurrent(attempt) || this.closed) return yield* cancelled;
          const committed = yield* Effect.result(
            this.#ports.change({ kind: "commit", issued: ref, supersede })
          );
          if (Result.isFailure(committed) || !isVault(committed.success)) {
            const queued = yield* this.#quarantine(ref);
            attempt.cleanupSettled = queued;
            if (!this.#isCurrent(attempt) || this.closed)
              return { kind: "cancelled" as const, needsRemoteCleanup: !queued };
            yield* this.#retireAttempt().wake;
            return {
              kind: "error" as const,
              needsRemoteCleanup: !queued,
              result: this.#problem(
                operation,
                "credential_mutation_uncertain",
                "authenticate"
              ) as Out,
            };
          }
          if (!this.#isCurrent(attempt) || this.closed) return yield* cancelled;
          for (const superseded of attempt.supersededAttempts) {
            superseded.cleanupSettled = true;
            if (superseded.committing) this.#unresolved.delete(superseded.committing);
          }
          attempt.cleanupSettled = true;
          this.#unresolved.delete(ref);
          this.attempt = undefined;
          this.#took(committed.success);
          this.#activeRef = ref;
          const snapshot = this.publishSignedIn(issued);
          return {
            kind: "success" as const,
            needsRemoteCleanup: false,
            result: { ok: true as const, value: snapshot } as Out,
          };
        })
      );
      if (settled.needsRemoteCleanup) {
        attempt.cleanupSettled = yield* this.#revokeRemotely(ref);
        if (attempt.cleanupSettled) {
          this.#unresolved.delete(ref);
          yield* Effect.ignore(this.#ports.change({ kind: "release", issued: ref }));
        }
      } else {
        this.fork(this.retryPendingRevocations());
      }
      if (settled.kind !== "cancelled") return settled.result;
      return this.failureOrUnknown(operation, "cancelled");
    });
  }

  /** Queues an issued credential for revocation (Main keeps it if it is the active one): true once it is. */
  #quarantine(ref: CredentialRef): Effect.Effect<boolean> {
    return this.#ports.change({ kind: "quarantine", issued: ref }).pipe(
      Effect.map((queued) => queued === true),
      Effect.orElseSucceed(() => false),
      Effect.tap((queued) =>
        Effect.sync(() => {
          if (queued) this.#unresolved.delete(ref);
        })
      )
    );
  }

  #retryUnsettled(attempts: readonly ElectronAttempt[]): Effect.Effect<boolean> {
    return Effect.gen({ self: this }, function* () {
      for (const attempt of new Set(attempts)) {
        if (attempt.cleanupSettled) continue;
        if (!attempt.committing) return false;
        attempt.cleanupSettled = yield* this.#quarantine(attempt.committing);
        if (!attempt.cleanupSettled) return false;
      }
      return true;
    });
  }

  #retryUnresolved(): Effect.Effect<boolean> {
    return Effect.gen({ self: this }, function* () {
      for (const ref of Array.from(this.#unresolved)) {
        if (yield* this.#quarantine(ref)) continue;
        if (yield* this.#revokeRemotely(ref)) {
          this.#unresolved.delete(ref);
          yield* Effect.ignore(this.#ports.change({ kind: "release", issued: ref }));
        }
      }
      return this.#unresolved.size === 0;
    });
  }

  // --- Attempts --------------------------------------------------------------------------------------------------

  /**
   * A new sign-in, retiring the one before: `wake` closes what waited on that one (its Google window). `retired` is
   * the new attempt's own retirement signal, made before any state was read.
   */
  #startAttempt(
    kind: ElectronAttempt["kind"],
    expected: SessionAbsenceExpectation,
    retired: Deferred.Deferred<void>
  ): { attempt: ElectronAttempt; wake: Effect.Effect<void> } | undefined {
    if (!this.#matches(expected)) return undefined;
    const phase = this.current.phase;
    if (phase !== "signed_out" && phase !== "authenticating") return undefined;
    const previous = this.attempt;
    const candidates = previous ? [previous, ...previous.supersededAttempts] : [];
    if (candidates.length > MAX_SUPERSEDED_AUTH_ATTEMPTS) return undefined;
    const { epoch: operationEpoch, wake } = this.#retireAttempt();
    const attempt: ElectronAttempt = {
      attempt: this.newAttempt(expected),
      cleanupSettled: true,
      isRetired: false,
      kind,
      operationEpoch,
      retired,
      supersededAttempts: [...new Set(candidates)],
    };
    this.attempt = attempt;
    this.publishTransient("authenticating");
    return { attempt, wake };
  }

  #matchingAttempt(
    input: { attempt: SessionAuthAttemptRef; challengeId: string },
    kind: ElectronAttempt["kind"]
  ): ElectronAttempt | undefined {
    const attempt = this.attempt;
    if (
      !attempt ||
      attempt.kind !== kind ||
      attempt.challengeId !== input.challengeId ||
      !sameAuthAttempt(attempt.attempt, input.attempt)
    )
      return undefined;
    return attempt;
  }

  /** Marks one operation of `attempt` under way (one at a time) with `inFlight`: the answer ends it. */
  #begin(
    attempt: ElectronAttempt,
    inFlight: Deferred.Deferred<void>
  ): Effect.Effect<void> | undefined {
    if (attempt.inFlight) return undefined;
    attempt.inFlight = inFlight;
    return Effect.suspend(() => {
      if (attempt.inFlight === inFlight) delete attempt.inFlight;
      return Deferred.succeed(inFlight, undefined);
    });
  }

  /**
   * Retires the sign-in under way (its answers are refused from now on): a new epoch. `wake` tells what waits on
   * its retirement (its Google window).
   */
  #retireAttempt(): { epoch: number; wake: Effect.Effect<void> } {
    const epoch = this.nextEpoch();
    const attempt = this.attempt;
    this.attempt = undefined;
    return { epoch, wake: attempt ? this.#retire(attempt) : Effect.void };
  }

  /** Marks `attempt` retired now; the effect tells what waits on it. */
  #retire(attempt: ElectronAttempt): Effect.Effect<void> {
    attempt.isRetired = true;
    return Deferred.succeed(attempt.retired, undefined).pipe(Effect.asVoid);
  }

  /** Runs `body` with a sign-in's signals, made before it reads or changes any state. */
  #withSignals<A>(
    body: (signals: {
      retired: Deferred.Deferred<void>;
      inFlight: Deferred.Deferred<void>;
    }) => Effect.Effect<A>
  ): Effect.Effect<A> {
    return Effect.all([Deferred.make<void>(), Deferred.make<void>()]).pipe(
      Effect.flatMap(([retired, inFlight]) => body({ retired, inFlight }))
    );
  }

  #isCurrent(attempt: ElectronAttempt): boolean {
    return (
      this.attempt === attempt &&
      !attempt.isRetired &&
      attempt.operationEpoch === this.epoch
    );
  }

  #settleAuthError<Operation extends SessionOperationName>(
    operation: Operation,
    attempt: ElectronAttempt,
    error: RemoteError,
    options: { retainRetryableAttempt?: boolean } = {}
  ): Effect.Effect<SessionOperationResult<never, Operation>> {
    return Effect.gen({ self: this }, function* () {
      const code = error.code !== "unauthorized" ? error.code : "unknown";
      const policy = sessionOperationErrorRule(operation, code as never);
      if (!this.#isCurrent(attempt))
        return this.failureOrUnknown(operation, "cancelled");
      if (policy?.retryable && options.retainRetryableAttempt !== false)
        return this.failureOrUnknown(operation, code, error.retryAfterMs);
      const retired = [attempt, ...attempt.supersededAttempts];
      const supersededInFlight = attempt.supersededAttempts.flatMap((candidate) =>
        candidate.inFlight ? [candidate.inFlight] : []
      );
      const epoch = this.nextEpoch();
      yield* this.#retire(attempt);
      yield* Effect.forEach(
        supersededInFlight,
        (deferred) => Deferred.await(deferred),
        {
          discard: true,
        }
      );
      if (this.attempt === attempt) this.attempt = undefined;
      return yield* this.#fenced(
        Effect.gen({ self: this }, function* () {
          if (!this.isCurrentEpoch(epoch) || this.closed)
            return this.failureOrUnknown(operation, "cancelled");
          if (!(yield* this.#retryUnsettled(retired)))
            return this.#problem(
              operation,
              "credential_mutation_uncertain",
              "authenticate"
            );
          this.publishSignedOut("no_session");
          return this.failureOrUnknown(operation, code, error.retryAfterMs);
        })
      );
    });
  }

  // --- The store as last read ------------------------------------------------------------------------------------

  /** What a read or change of the store says: the credentials still to revoke, and the accounts kept. */
  #took(vault: BearerVault | boolean | null): void {
    if (!isVault(vault) || vault.status !== "readable") return;
    this.cleanup = vault.cleanup;
    this.#keep(vault);
  }

  /** The accounts the store keeps signed in besides the one in use (this audience's; one per account). */
  #keep(vault: Extract<BearerVault, { status: "readable" }>): void {
    const kept = (vault.kept ?? []).filter(
      (credential) => credential.audience === this.origin
    );
    this.#keptRefs = kept;
    this.kept = kept.map(({ audience, userId, email }) => ({
      audience,
      userId,
      email,
    }));
  }

  // --- Fencing ---------------------------------------------------------------------------------------------------

  /** `effect` once every earlier change of the credential store and its publication has ended. */
  #fenced<A>(effect: Effect.Effect<A>): Effect.Effect<A> {
    return this.#fence.withPermits(1)(effect);
  }

  #matches(expected: SessionLifecycleExpectation | undefined): boolean {
    if (!expected) return false;
    if (this.localExpectationMatches(expected)) return true;
    const attempt = this.attempt;
    return (
      this.current.phase === "authenticating" &&
      attempt !== undefined &&
      sameExpectation(expected, attempt.attempt.expected)
    );
  }

  #problem<Operation extends SessionOperationName>(
    operation: Operation,
    code: ProblemCode,
    problemOperation: ProblemOperation
  ): SessionOperationResult<never, Operation> {
    this.publishIndeterminate(code, problemOperation);
    return this.failureOrUnknown(operation, code);
  }

  #publishProblem(problem: SessionProblem): void {
    this.publishIndeterminate(problem.code as ProblemCode, problem.operation);
  }

  // --- Requests --------------------------------------------------------------------------------------------------

  #clientMetadata() {
    return {
      client_kind: this.#ports.clientKind ?? "electron",
      client_platform: this.#ports.clientPlatform,
    } as const;
  }

  /**
   * An auth request through Main (the credential named attached there, a bearer in the answer kept there), given up
   * after 5 s: its answer as `schema` reads it, or why there was none.
   */
  #request<S extends z.ZodType>(
    method: "GET" | "POST",
    path: string,
    schema: S,
    options: {
      body?: Record<string, unknown>;
      credential?: CredentialRef;
      protect?: true;
    } = {}
  ): Effect.Effect<z.output<S>, RemoteError> {
    const send = (
      route: string,
      payload?: Record<string, unknown>
    ): Effect.Effect<AuthResponse, RemoteError> =>
      Effect.suspend(() =>
        this.#authFetch({
          method,
          path: route,
          headers: payload
            ? [
                ["accept", "application/json"],
                ["content-type", "application/json"],
              ]
            : [["accept", "application/json"]],
          body: payload ? utf8(JSON.stringify(payload)) : null,
          ...(options.credential ? { credential: options.credential } : {}),
        })
      ).pipe(
        Effect.timeoutOrElse({
          duration: REQUEST_TIMEOUT_MS,
          orElse: () => Effect.fail(new HostError("the request took too long")),
        }),
        Effect.mapError(() => new RemoteError("network_unavailable")),
        Effect.map((response) => ({
          ok: response.status >= 200 && response.status < 300,
          status: response.status,
          headers: response.headers,
          body: jsonBody(response.body),
        }))
      );
    const retired = this.attempt?.retired;
    const request =
      options.protect && options.body
        ? this.protectedAuthRequest(path, options.body, send).pipe(
            Effect.mapError((error) =>
              error instanceof AbuseError ? new RemoteError(error.code) : error
            )
          )
        : send(path, options.body);
    const active =
      options.protect && retired
        ? Effect.raceFirst(
            request,
            Deferred.await(retired).pipe(
              Effect.andThen(Effect.fail(new RemoteError("cancelled")))
            )
          )
        : request;
    return active.pipe(
      Effect.flatMap((response) => {
        if (!response) return Effect.fail(new RemoteError("network_unavailable"));
        if (response.status >= 300 && response.status < 400)
          return Effect.fail(new RemoteError("protocol_mismatch"));
        const body = response.body;
        if (!response.ok)
          return Effect.fail(
            remoteError(
              { status: response.status, headers: response.headers ?? [] },
              body
            )
          );
        if (body === undefined)
          return Effect.fail(new RemoteError("protocol_mismatch"));
        const out = schema.safeParse(body);
        if (out.success) return Effect.succeed(out.data as z.output<S>);
        const ref = (body as { credential?: unknown } | null)?.credential;
        return (
          typeof ref === "string" ? Effect.asVoid(this.#quarantine(ref)) : Effect.void
        ).pipe(Effect.andThen(Effect.fail(new RemoteError("protocol_mismatch"))));
      })
    );
  }
}

function isVault(value: BearerVault | boolean | null): value is BearerVault {
  return typeof value === "object" && value !== null;
}

function jsonBody(body: Uint8Array): unknown {
  const text = fromUtf8(body);
  if (text === "") return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function remoteError(
  response: Pick<ApiResponse, "status" | "headers">,
  body: unknown
): RemoteError {
  const retryAfter = response.headers.find(
    ([name]) => name.toLowerCase() === "retry-after"
  )?.[1];
  const retryAfterMs =
    retryAfter && Number.isFinite(Number(retryAfter))
      ? Math.max(1, Math.trunc(Number(retryAfter) * 1_000))
      : undefined;
  const error = (body as { error?: unknown } | null | undefined)?.error;
  const code = typeof error === "string" && error.length <= 256 ? error : undefined;
  if (code === "invalid_verification_code") return new RemoteError("invalid_challenge");
  if (code === "invalid_google_attempt" || code === "invalid_apple_attempt")
    return new RemoteError("challenge_expired");
  if (code === "disabled") return new RemoteError("account_disabled");
  if (
    code === "auth_unavailable" ||
    code === "email_delivery_unavailable" ||
    code === "google_not_configured" ||
    code === "google_provider_unavailable" ||
    code === "apple_not_configured" ||
    code === "apple_provider_unavailable"
  )
    return new RemoteError("provider_unavailable", retryAfterMs);
  if (
    code === "google_link_changed" ||
    code === "apple_link_changed" ||
    code === "identity_conflict" ||
    code === "provider_already_linked"
  )
    return new RemoteError("conflict");
  if (response.status === 401) return new RemoteError("unauthorized");
  if (response.status === 403) return new RemoteError("account_disabled");
  if (response.status === 409) return new RemoteError("conflict");
  if (response.status === 429) return new RemoteError("rate_limited", retryAfterMs);
  if (response.status === 503)
    return new RemoteError("provider_unavailable", retryAfterMs);
  return new RemoteError("unknown");
}

function sameExpectation(
  left: SessionLifecycleExpectation,
  right: SessionLifecycleExpectation
): boolean {
  if (
    left.authorityInstanceId !== right.authorityInstanceId ||
    left.generation !== right.generation ||
    left.expectedSessionId !== right.expectedSessionId
  )
    return false;
  if (left.expectedSessionId === null || right.expectedSessionId === null)
    return left.expectedSessionId === right.expectedSessionId;
  return (
    "expectedAudience" in left &&
    "expectedAudience" in right &&
    left.expectedAudience === right.expectedAudience
  );
}

function sameAuthAttempt(left: SessionAuthAttemptRef, right: SessionAuthAttemptRef) {
  return (
    left.attemptId === right.attemptId && sameExpectation(left.expected, right.expected)
  );
}
