// The web session lifecycle, run by the core: what the session Cookie (httpOnly, never read by JavaScript) holds, how
// a person signs in (an emailed code, Google, a guest session, a Telegram launch) and out, and what happens when the
// server refuses a product request for the session. It is the retired page adapter's state machine moved into the
// core: the same phases, snapshots,
// generation and revision rules, recovery tickets (at most 2 attempts within 20 s, 250 ms apart), background
// re-probes of a signed-in session the server could not be asked about (1, 3, 10, 30 s), 8 s per request, and the
// guest proof of work retried once. Every wait is on the core's Clock; every request goes through the host's
// `authFetch` (the Cookie, and the session headers naming the session expected). What it publishes feeds `Session`
// (session.ts) as `session.observe` did, so the account, the lease and the refusals work as before; a refusal of the
// current lease (`Session.rejected`) comes back here: a 401 invalidates the session, a 409 rebinds to what the Cookie
// holds now. Closing the lease stops the product requests still under way with it (api.ts), as the adapter's lease
// signal aborted them. A burst of refusals or hints runs one reconcile per expectation, not one each. A defect (a
// bug, a host port that threw) fails the operation as the adapter's try/catch did, and never leaves the snapshot in
// a phase nothing would end. The publishing, fencing and re-probes are the state machine it shares with Electron's
// lifecycle (lifecycle.ts); what is here is the Cookie's part.
//
// Coordination. One core runs per origin (the worker holding the `comma-core` Web Lock), so the core is the one
// writer of the session for every tab: a tab's page is one of its UIs, and all of them see one snapshot. What the
// adapter kept in localStorage — the Cookie authority, its generation, the record's revision, the operation in flight
// with its deadline, the recovery ticket — the core keeps in the host's device storage (`storageGet`/`storageSet`),
// written before each request that may change the Cookie and read back. When the tab running the core closes, the
// next tab's worker starts a new core on the same storage: it starts as a page did (`initializing`, then the startup
// probe) and applies the adapter's rules to what it finds: an operation still in flight is one whose answer was lost
// (its core went with it), so the Cookie may hold anything — a new authority, an unknown recovery (a probe expecting
// nothing in particular, then adopt what the server says); a recovery ticket whose attempt was in flight is ready
// again, or exhausted when its attempts or window are used up. The new core goes on as the same authority (its id,
// generation and revision, kept in device storage), so when it finds the same session the pages keep their view and
// lease. A sign-in under way does not survive a handoff (its attempt was the old core's); the person starts it again.
//
// Every page of the origin (the app, the Telegram Task panel) is a UI of this core. A page of an older build still open
// across an update runs the page adapter this replaced, which shares the Cookie: against it the core keeps what works
// in a worker. Every change of the Cookie happens under the same Web Lock the adapter took
// (`comma.session-lifecycle.v1:<origin>`), and each change is announced on the same BroadcastChannel with the same
// hint; a hint from another context makes the core check the session with the server (a peer reconcile). The
// adapter's localStorage record is not kept: a worker cannot reach localStorage, and the record is no authority — each
// probe names the session its writer expects, and the server answers 409 (another session), 401 (none) or the
// session, so an adapter that finds its record stale rebinds to what the server says. The core's device storage is
// the only record it reads.
import {
  createSessionOperationErrorOrUnknown,
  guestAvailabilityRemoteSchema,
  sessionExpectation,
  sessionPrincipalKind,
  sessionProductLease,
  type SessionAbsenceExpectation,
  type SessionAuthAttemptRef,
  type SessionLifecycleExpectation,
  type SessionOperationErrorCode,
  type SessionOperationErrorCodeFor,
  type SessionOperationName,
  type SessionOperationResult,
  type SignedInSessionSnapshot,
  type SignedOutSessionSnapshot,
  type TerminalSessionSnapshot,
} from "@comma/session-contract";
import { fromUtf8, HostError, utf8 } from "@comma/core-kernel";
import { Effect, type Fiber, Result } from "effect";
import type { z } from "zod";
import type {
  SessionEmailChallenge,
  SessionGoogleAttempt,
  SessionGoogleSignIn,
} from "../contract.ts";
import {
  type ApiResponse,
  type AuthRequest,
  type HintChannel,
  HostUnsupported,
  type SessionLease,
  type WebSessionPorts,
} from "../host.ts";
import { type LifecycleDeps, SessionLifecycle } from "./lifecycle.ts";
import {
  authStartRefusal,
  type AuthResponse,
  clientMetadata,
  emailChallenge,
  googleAttempt,
  googleCompletion,
  googleLinkChallenge,
  guestHandoff,
  guestImportAnswer,
  guestImportMarker,
  guestStartRefusal,
  isGuestPowRejection,
  isProtocolError,
  parsed,
  type SessionProjection,
  sessionChanged,
  sessionProjection,
  signedOutAnswer,
  solveGuestPow,
  unauthorized,
} from "./web-auth.ts";
import {
  checkedRecord,
  guestImportMarkerKey,
  type InFlightOperation,
  type InFlightRecord,
  readRecord,
  type RecordBody,
  type RecordRead,
  recordSessionId,
  type RecoveringRecord,
  type SettledRecord,
  settledStateOf,
  type WebSessionRecord,
  webSessionAuthorityKey,
  webSessionAuthoritySchema,
  webSessionChannelName,
  webSessionLockName,
  webSessionStorageKey,
} from "./web-record.ts";

const LOCK_ACQUIRE_TIMEOUT_MS = 2_000;
const REQUEST_TIMEOUT_MS = 8_000;
const RECOVERY_WINDOW_MS = 20_000;
const RECOVERY_BACKOFF_MS = 250;
const RECOVERY_MAX_ATTEMPTS = 2;
/** How long a guest's claim is taken to last when the handoff's answer did not say. */
const GUEST_CLAIM_FALLBACK_S = 60 * 60;

/** Why an operation could not run: no Web Locks, the lock not had in time, the record not kept, the lock refused. */
class Fault extends Error {
  constructor(
    readonly kind: "unsupported" | "lock_timeout" | "storage" | "other",
    message: string
  ) {
    super(message);
  }
}

type Op<A> = Effect.Effect<A, Fault>;

/** The Cookie as the core last adopted it from the record. */
type Adopted = {
  cookieAuthorityId: string;
  cookieGeneration: number;
  coordinationRevision: number;
  sessionId: string | null | undefined;
};

type CookieIdentity = { cookieAuthorityId: string; cookieGeneration: number };

type Hint = {
  canonicalApiOrigin: string;
  cookieAuthorityId: string;
  cookieGeneration: number;
  coordinationRevision: number;
  kind: "session_maybe_changed";
  schemaVersion: 1;
  senderId: string;
};

export type TelegramResult = "signed_in" | "failed" | "account_mismatch";

export type WebLifecycleDeps = LifecycleDeps;

export class WebSessionLifecycle extends SessionLifecycle {
  readonly origin: string;
  readonly #authFetch: (request: AuthRequest) => Effect.Effect<ApiResponse, HostError>;
  readonly #ports: WebSessionPorts;
  readonly #storageKey: string;
  readonly #markerKey: string;
  readonly #lockName: string;
  readonly #senderId: string;
  readonly #channel: HintChannel;
  readonly #unlisten: () => void;
  readonly #authorityKey: string;
  #adopted: Adopted | undefined;
  #guestImport: Fiber.Fiber<unknown, unknown> | null = null;

  constructor(deps: WebLifecycleDeps) {
    super(deps, "web_cookie");
    const { host } = deps;
    if (!host.authFetch || !host.webSession)
      throw new Error(
        "the web session lifecycle needs the host's authFetch and webSession"
      );
    this.#authFetch = host.authFetch.bind(host);
    this.#ports = host.webSession;
    this.origin = this.#ports.apiOrigin;
    this.#senderId = this.randomId();
    this.#storageKey = webSessionStorageKey(this.origin);
    this.#markerKey = guestImportMarkerKey(this.origin);
    this.#authorityKey = webSessionAuthorityKey(this.origin);
    this.#lockName = webSessionLockName(this.origin);
    this.#channel = this.#ports.channel(webSessionChannelName(this.origin));
    this.#unlisten = this.#channel.listen((hint) => this.#hint(hint));
    this.sync();
  }

  /** Finds out what the Cookie holds (the core started), as the authority the core before it was, if there was one. */
  start(): void {
    this.fork(
      Effect.andThen(this.#resumeAuthority(), this.reconcile({ reason: "startup" }))
    );
  }

  /** Continues the authority of the core that ran before (its tab closed), kept in device storage. */
  #resumeAuthority(): Effect.Effect<void> {
    return this.host.storageGet(this.#authorityKey).pipe(
      Effect.map((raw) => {
        if (!raw) return;
        let json: unknown;
        try {
          json = JSON.parse(fromUtf8(raw));
        } catch {
          return;
        }
        const saved = webSessionAuthoritySchema.safeParse(json);
        if (saved.success) this.resumeFrom(saved.data);
      }),
      Effect.ignore
    );
  }

  override close(): void {
    if (this.closed) return;
    super.close();
    this.#unlisten();
    this.#channel.close();
  }

  protected audience(): string {
    return this.origin;
  }

  protected override indeterminateSessionId(): string | null | undefined {
    return this.#adopted?.sessionId;
  }

  protected override credentialHeld(sessionId: string): boolean {
    return this.#adopted !== undefined && this.#adopted.sessionId === sessionId;
  }

  protected override onGateClosed(): void {
    if (this.#guestImport !== null) this.runner.interrupt(this.#guestImport);
    this.#guestImport = null;
  }

  protected override onSignedIn(guest: boolean): void {
    if (!guest) this.#redeemGuestImport();
  }

  // --- What the UI calls ---------------------------------------------------------------------------------------

  override recover(): Effect.Effect<void> {
    return Effect.suspend((): Effect.Effect<void> => {
      if (this.current.phase === "initializing")
        return Effect.asVoid(this.reconcile({ reason: "startup" }));
      const expected = this.expectation();
      if (expected)
        return Effect.asVoid(this.reconcile({ expected, reason: "manual_retry" }));
      if (
        this.current.phase !== "indeterminate" ||
        this.#adopted?.sessionId !== undefined
      )
        return Effect.void;
      const epoch = this.nextEpoch();
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureManualRecoveryRecord();
          if (record.kind === "recovering") yield* this.#runRecovery(record, epoch);
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => void this.#lifecycleFailure(fault, epoch))
        )
      );
    });
  }

  telegram(input: {
    initData: string;
    groupId: string;
  }): Effect.Effect<TelegramResult> {
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const read = yield* this.#read();
          // A signed launch is an explicit sign-in: recovery is persisted before the server can replace the
          // Cookie, so a lost answer is recovered from.
          const recovery = yield* this.#createUnknownRecovery(
            read.kind === "valid" ? read.record : undefined
          );
          this.attempt = undefined;
          this.revoke();
          this.#adopt(recovery);
          this.publishTransient("authenticating");
          const response = yield* this.#request(
            "POST",
            "/v1/comma/auth/telegram-miniapp",
            "unknown",
            {
              init_data: input.initData,
              group_id: input.groupId,
            }
          );
          if (!response) {
            this.publishIndeterminate("credential_mutation_uncertain", "authenticate");
            return "failed" as const;
          }
          if (!response.ok) {
            this.publishIndeterminate("protocol_mismatch", "authenticate");
            return response.status === 409
              ? ("account_mismatch" as const)
              : ("failed" as const);
          }
          const projection = parsed(response, sessionProjection);
          if (!projection) {
            this.publishIndeterminate("protocol_mismatch", "authenticate");
            return "failed" as const;
          }
          const stable = yield* this.#writeNext(
            recovery,
            {
              kind: "stable",
              state: { kind: "present", sessionId: projection.session_id },
            },
            recovery.cookieGeneration + 1
          );
          this.#adopt(stable);
          this.publishSignedIn(projection);
          this.#publishHint(stable);
          return "signed_in" as const;
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => {
            this.#lifecycleFailure(fault, epoch);
            return "failed" as const;
          })
        )
      );
    });
  }

  reconcile(input: {
    expected?: SessionLifecycleExpectation;
    reason: "startup" | "focus" | "manual_retry" | "peer_mutation";
  }): Effect.Effect<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    return Effect.suspend(() => {
      if (input.expected && !this.localExpectationMatches(input.expected))
        return Effect.succeed(this.failure("reconcile", "conflict"));
      if (
        !input.expected &&
        (input.reason !== "startup" || this.current.phase !== "initializing")
      )
        return Effect.succeed(this.failure("reconcile", "conflict"));
      // A rejected wake or peer hint must not cancel an admitted probe's completion.
      const epoch = this.nextEpoch();
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          // A newer wake may have superseded this probe while it waited for the lock.
          if (!this.isCurrentEpoch(epoch)) return this.failure("reconcile", "conflict");
          const record =
            input.reason === "manual_retry"
              ? yield* this.#ensureManualRecoveryRecord()
              : yield* this.#ensureRecoverableRecord();
          if (record.kind === "recovering")
            return yield* this.#runRecovery(record, epoch);
          if (record.kind === "in_flight") return this.failure("reconcile", "conflict");
          return yield* this.#runProbe(record, epoch, input.expected);
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#lifecycleFailure(fault, epoch))
        )
      );
    });
  }

  protected requestEmailChallenge(input: {
    email: string;
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<
    SessionOperationResult<SessionEmailChallenge, "request_email_login">
  > {
    const operation = "request_email_login" as const;
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      const attempt = this.newAttempt(input.expected);
      if (!this.canStartAuthentication(input.expected))
        return Effect.succeed(this.failure(operation, "conflict"));
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (!this.#canCommitAuthAttempt(record, input.expected))
            return this.failure(operation, "conflict");
          const authenticating = yield* this.#writeNext(record, {
            activeAuthAttemptId: attempt.attemptId,
            kind: "authenticating",
            operationEpoch: epoch,
            state: { kind: "absent" },
          });
          this.attempt = { attempt, kind: "email", operationEpoch: epoch };
          this.#adopt(authenticating);
          this.publishTransient("authenticating");
          const response = yield* this.#request(
            "POST",
            "/v1/comma/auth/email/login",
            "none",
            {
              email: input.email.trim(),
            }
          );
          if (!response) {
            yield* this.#clearAttemptIfCurrent(authenticating, attempt.attemptId);
            return this.failure(operation, "network_unavailable");
          }
          if (response.ok) {
            const challenge = parsed(response, emailChallenge);
            if (!challenge) {
              yield* this.#clearAttemptIfCurrent(authenticating, attempt.attemptId);
              return this.failure(operation, "protocol_mismatch");
            }
            if (!this.isCurrentAttempt(attempt, epoch))
              return this.failure(operation, "conflict");
            // The address goes with the challenge (in memory only), so any tab shows where the code went.
            this.attempt = {
              attempt,
              challengeId: challenge.challenge_id,
              email: input.email.trim(),
              kind: "email",
              operationEpoch: epoch,
            };
            this.sync();
            return {
              ok: true as const,
              value: {
                attempt,
                challengeId: challenge.challenge_id,
                ...(challenge.code ? { code: challenge.code } : {}),
              },
            };
          }
          yield* this.#clearAttemptIfCurrent(authenticating, attempt.attemptId);
          return this.failure(operation, authStartRefusal(response));
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch))
        )
      );
    });
  }

  verifyEmailLogin(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Effect.Effect<
    SessionOperationResult<SignedInSessionSnapshot, "verify_email_login">
  > {
    return this.#completeAuth({
      attempt: input.attempt,
      body: { challenge_id: input.challengeId, code: input.code },
      kind: "verify_email_login",
      operation: "verify_email_login",
      path: "/v1/comma/auth/email/verify",
      schema: sessionProjection,
      unauthorizedCode: "invalid_challenge",
      settle: (projection) => ({ kind: "signed_in", projection }),
      value: (snapshot) => snapshot,
    });
  }

  beginGoogleLogin(input: {
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<
    SessionOperationResult<SessionGoogleAttempt, "sign_in_with_google">
  > {
    const operation = "sign_in_with_google" as const;
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      const attempt = this.newAttempt(input.expected);
      if (!this.canStartAuthentication(input.expected))
        return Effect.succeed(this.failure(operation, "conflict"));
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (!this.#canCommitAuthAttempt(record, input.expected))
            return this.failure(operation, "conflict");
          const authenticating = yield* this.#writeNext(record, {
            activeAuthAttemptId: attempt.attemptId,
            kind: "authenticating",
            operationEpoch: epoch,
            state: { kind: "absent" },
          });
          this.attempt = { attempt, kind: "google", operationEpoch: epoch };
          this.#adopt(authenticating);
          this.publishTransient("authenticating");
          const response = yield* this.#request(
            "POST",
            "/v1/comma/auth/google/attempt",
            "none",
            {
              platform: "web",
            }
          );
          if (!response) {
            yield* this.#clearAttemptIfCurrent(authenticating, attempt.attemptId);
            return this.failure(operation, "network_unavailable");
          }
          if (!response.ok) {
            yield* this.#clearAttemptIfCurrent(authenticating, attempt.attemptId);
            return this.failure(operation, authStartRefusal(response));
          }
          const prepared = parsed(response, googleAttempt);
          if (!prepared || !this.isCurrentAttempt(attempt, epoch)) {
            yield* this.#clearAttemptIfCurrent(authenticating, attempt.attemptId);
            return this.failure(operation, prepared ? "conflict" : "protocol_mismatch");
          }
          return {
            ok: true as const,
            value: {
              attempt,
              clientId: prepared.client_id,
              nonce: prepared.nonce,
              providerAttemptId: prepared.attempt_id,
            },
          };
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch))
        )
      );
    });
  }

  completeGoogleLogin(input: {
    attempt: SessionAuthAttemptRef;
    credential: string;
    nonce: string;
    providerAttemptId: string;
  }): Effect.Effect<
    SessionOperationResult<SessionGoogleSignIn, "sign_in_with_google">
  > {
    return this.#completeAuth({
      attempt: input.attempt,
      body: {
        attempt_id: input.providerAttemptId,
        credential: input.credential,
        nonce: input.nonce,
      },
      kind: "complete_google_login",
      operation: "sign_in_with_google",
      path: "/v1/comma/auth/google",
      schema: googleCompletion,
      unauthorizedCode: "unknown",
      settle: (value) =>
        "status" in value
          ? { kind: "otp_required", value }
          : { kind: "signed_in", projection: value },
      value: (snapshot): SessionGoogleSignIn => ({ snapshot, status: "signed_in" }),
    });
  }

  verifyGoogleLink(input: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
    code: string;
  }): Effect.Effect<
    SessionOperationResult<SignedInSessionSnapshot, "verify_google_link">
  > {
    return this.#completeAuth({
      attempt: input.attempt,
      body: { challenge_id: input.challengeId, code: input.code },
      kind: "verify_google_link",
      operation: "verify_google_link",
      path: "/v1/comma/auth/google/link/verify",
      schema: sessionProjection,
      unauthorizedCode: "invalid_challenge",
      settle: (projection) => ({ kind: "signed_in", projection }),
      value: (snapshot) => snapshot,
    });
  }

  /** Whether the server offers guest sessions. Any failure reads as off. */
  guestAvailability(): Effect.Effect<boolean> {
    return this.#request("GET", "/v1/comma/auth/guest", "none").pipe(
      Effect.map((response) => {
        if (!response?.ok) return false;
        return parsed(response, guestAvailabilityRemoteSchema)?.enabled === true;
      })
    );
  }

  startGuestSession(input: {
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<
    SessionOperationResult<SignedInSessionSnapshot, "start_guest_session">
  > {
    const operation = "start_guest_session" as const;
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      const attempt = this.newAttempt(input.expected);
      if (!this.canStartAuthentication(input.expected))
        return Effect.succeed(this.failure(operation, "conflict"));
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (!this.#canCommitAuthAttempt(record, input.expected))
            return this.failure(operation, "conflict");
          this.attempt = { attempt, kind: "guest", operationEpoch: epoch };
          this.publishTransient("authenticating");
          // One solved challenge creates at most one guest. A challenge can expire or the difficulty rise before the
          // create request, so a rejected proof is retried once with a fresh one.
          let settled: SettledRecord = record;
          for (let round = 0; ; round += 1) {
            const solved = yield* this.#solveGuestChallenge();
            if (!solved.ok) {
              this.attempt = undefined;
              this.publishSignedOut("no_session");
              return this.failure(operation, solved.code);
            }
            const marker = yield* this.#writeInFlight(settled, epoch, {
              authAttemptId: attempt.attemptId,
              expectedSessionId: "none",
              kind: "start_guest_session",
            });
            const response = yield* this.#request(
              "POST",
              "/v1/comma/auth/guest",
              "none",
              {
                ...clientMetadata(this.#ports.userAgent),
                pow: solved.value,
              }
            );
            if (!response) {
              // The server may have set a guest Cookie: recovery probes it.
              this.attempt = undefined;
              this.publishIndeterminate(
                "credential_mutation_uncertain",
                "authenticate"
              );
              return this.failure(operation, "credential_mutation_uncertain");
            }
            if (response.ok) {
              const projection = parsed(response, sessionProjection);
              if (projection) {
                const stable = yield* this.#writeNext(
                  marker,
                  {
                    kind: "stable",
                    state: { kind: "present", sessionId: projection.session_id },
                  },
                  marker.cookieGeneration + 1
                );
                this.attempt = undefined;
                this.#adopt(stable);
                const snapshot = this.publishSignedIn(projection);
                this.#publishHint(stable);
                return { ok: true as const, value: snapshot };
              }
              this.attempt = undefined;
              this.#adopt(yield* this.#restoreAfterResponse(marker));
              this.publishIndeterminate("protocol_mismatch", "authenticate");
              return this.failure(operation, "protocol_mismatch");
            }
            // A refused start leaves no Cookie behind.
            const absent = yield* this.#writeNext(marker, {
              kind: "stable",
              state: { kind: "absent" },
            });
            this.#adopt(absent);
            if (round === 0 && isGuestPowRejection(response)) {
              settled = absent;
              continue;
            }
            this.attempt = undefined;
            this.publishSignedOut("no_session");
            return this.failure(operation, guestStartRefusal(response));
          }
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch))
        )
      );
    });
  }

  /**
   * Ends the current guest session. The server clears the session Cookie and sets an httpOnly claim Cookie; the core
   * notes only that an import waits, so the next registered sign-in redeems the claim.
   */
  beginGuestSignUp(input: {
    expected: SessionLifecycleExpectation;
  }): Effect.Effect<
    SessionOperationResult<SignedOutSessionSnapshot, "begin_guest_sign_up">
  > {
    const operation = "begin_guest_sign_up" as const;
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      const current = this.current;
      if (
        current.phase !== "signed_in" ||
        sessionPrincipalKind(current.principal) !== "guest" ||
        !this.localExpectationMatches(input.expected)
      )
        return Effect.succeed(this.failure(operation, "conflict"));
      const expectedSessionId = current.session.sessionId;
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (!this.#recordMatchesCurrentLease(record, expectedSessionId))
            return this.failure(operation, "conflict");
          // The handoff clears the session Cookie exactly as signing out does.
          const marker = yield* this.#writeInFlight(record, epoch, {
            expectedSessionId,
            kind: "sign_out",
          });
          // Written first: a lost answer may still have set the claim Cookie. A redemption without it is refused and
          // clears the marker.
          yield* this.#writeMarker(
            Math.floor(this.now() / 1_000) + GUEST_CLAIM_FALLBACK_S
          );
          const response = yield* this.#request(
            "POST",
            "/v1/comma/auth/guest/handoff",
            expectedSessionId,
            {}
          );
          if (!response) {
            yield* this.#restoreAfterResponse(marker);
            return this.failure(operation, "network_unavailable");
          }
          if (response.ok) {
            const handoff = parsed(response, guestHandoff);
            if (handoff) yield* this.#writeMarker(handoff.expires_at);
            return {
              ok: true as const,
              value: yield* this.#settleSignedOut(marker, "guest_handoff"),
            };
          }
          yield* this.#clearMarker();
          if (response.status === 401 && parsed(response, unauthorized))
            return {
              ok: true as const,
              value: yield* this.#settleSignedOut(marker, "unauthorized"),
            };
          yield* this.#restoreAfterResponse(marker);
          return this.failure(
            operation,
            response.status === 429
              ? "rate_limited"
              : response.status >= 500
                ? "provider_unavailable"
                : response.status === 403
                  ? "conflict"
                  : "unknown"
          );
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch))
        )
      );
    });
  }

  cancelAuthAttempt(input: {
    attempt: SessionAuthAttemptRef;
  }): Effect.Effect<
    SessionOperationResult<SignedOutSessionSnapshot, "cancel_auth_attempt">
  > {
    const operation = "cancel_auth_attempt" as const;
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      if (!this.isCurrentAttempt(input.attempt))
        return Effect.succeed(this.failure(operation, "conflict"));
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (
            record.kind !== "authenticating" ||
            record.activeAuthAttemptId !== input.attempt.attemptId
          )
            return this.failure(operation, "conflict");
          const stable = yield* this.#writeNext(record, {
            kind: "stable",
            state: { kind: "absent" },
          });
          this.attempt = undefined;
          this.#adopt(stable);
          return { ok: true as const, value: this.publishSignedOut("no_session") };
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch))
        )
      );
    });
  }

  signOut(input: {
    expected: SessionLifecycleExpectation;
  }): Effect.Effect<SessionOperationResult<SignedOutSessionSnapshot, "sign_out">> {
    const operation = "sign_out" as const;
    return Effect.suspend(() => {
      const epoch = this.nextEpoch();
      const current = this.current;
      if (
        current.phase === "signed_out" &&
        this.localExpectationMatches(input.expected)
      )
        return Effect.succeed({ ok: true as const, value: current });
      if (
        current.phase !== "signed_in" ||
        !this.localExpectationMatches(input.expected)
      )
        return Effect.succeed(this.failure(operation, "conflict"));
      const expectedSessionId = current.session.sessionId;
      this.publishTransient("signing_out");
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (!this.#recordMatchesCurrentLease(record, expectedSessionId)) {
            this.publishIndeterminate("protocol_mismatch", "sign_out");
            return this.failure(operation, "conflict");
          }
          const marker = yield* this.#writeInFlight(record, epoch, {
            expectedSessionId,
            kind: "sign_out",
          });
          const response = yield* this.#request(
            "POST",
            "/v1/comma/auth/logout",
            expectedSessionId,
            {}
          );
          if (!response) {
            this.publishIndeterminate("credential_mutation_uncertain", "sign_out");
            return this.failure(operation, "credential_mutation_uncertain");
          }
          if (response.ok) {
            if (!parsed(response, signedOutAnswer)) {
              yield* this.#restoreAfterResponse(marker);
              this.publishIndeterminate("protocol_mismatch", "sign_out");
              return this.failure(operation, "protocol_mismatch");
            }
            return {
              ok: true as const,
              value: yield* this.#settleSignedOut(marker, "user_signed_out"),
            };
          }
          if (response.status === 401 && parsed(response, unauthorized))
            return {
              ok: true as const,
              value: yield* this.#settleSignedOut(marker, "unauthorized"),
            };
          yield* this.#restoreAfterResponse(marker);
          this.publishIndeterminate(
            response.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch",
            "sign_out"
          );
          return this.failure(
            operation,
            response.status >= 500 ? "network_unavailable" : "protocol_mismatch"
          );
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch))
        )
      );
    });
  }

  // --- A product request refused ---------------------------------------------------------------------------------

  /** The server answered 401 to a product request made with `lease`. */
  productUnauthorized(lease: SessionLease): void {
    if (!this.#isCurrentProductLease(lease)) return;
    const epoch = this.nextEpoch();
    // The lease is current, so the Cookie adopted now is the one it was refused under.
    const adopted = this.#adopted;
    const cookie: CookieIdentity | undefined = adopted && {
      cookieAuthorityId: adopted.cookieAuthorityId,
      cookieGeneration: adopted.cookieGeneration,
    };
    // A product 401 ends this lease: the gate closes before waiting for the lock, so no request reuses it.
    this.revoke();
    this.fork(
      this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (
            !this.isCurrentEpoch(epoch) ||
            !cookie ||
            !this.#isCurrentProductLeaseIdentity(lease, cookie) ||
            !this.#recordMatchesLease(record, lease, cookie)
          )
            return;
          const marker = yield* this.#writeInFlight(
            record,
            epoch,
            {
              expectedSessionId: lease.sessionId,
              kind: "product_unauthorized_reconcile",
            },
            record.cookieGeneration + 1
          );
          this.#publishHint(marker);
          this.publishTransient("invalidating");
          const response = yield* this.#request(
            "GET",
            "/v1/comma/auth/session",
            lease.sessionId
          );
          if (!response) {
            const recovering = yield* this.#writeExactSessionRecovery(
              marker,
              lease.sessionId
            );
            this.#adopt(recovering);
            this.publishIndeterminate("credential_mutation_uncertain", "invalidate");
            this.#publishHint(recovering);
            return;
          }
          if (response.ok) {
            const projection = parsed(response, sessionProjection);
            if (projection?.session_id === lease.sessionId) {
              const stable = yield* this.#writeNext(marker, {
                kind: "stable",
                state: { kind: "present", sessionId: lease.sessionId },
              });
              this.#adopt(stable);
              this.publishSignedIn(projection);
              this.#publishHint(stable);
              return;
            }
          } else if (response.status === 401 && parsed(response, unauthorized)) {
            yield* this.#settleSignedOut(marker, "unauthorized");
            return;
          } else if (response.status === 409 && parsed(response, sessionChanged)) {
            yield* this.#rebindToCurrentCookie(
              yield* this.#restoreAfterResponse(marker),
              epoch
            );
            return;
          }
          if (response.status >= 500) {
            const recovering = yield* this.#writeExactSessionRecovery(
              marker,
              lease.sessionId
            );
            this.#adopt(recovering);
            this.publishIndeterminate("session_probe_unavailable", "invalidate");
            this.#publishHint(recovering);
            return;
          }
          yield* this.#restoreAfterResponse(marker);
          this.publishIndeterminate("protocol_mismatch", "invalidate");
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => void this.#lifecycleFailure(fault, epoch))
        )
      )
    );
  }

  /** The server answered 409 (another session) to a product request made with `lease`. */
  productSessionChanged(lease: SessionLease): void {
    const current = this.current;
    if (!this.#isCurrentProductLease(lease) || current.phase !== "signed_in") return;
    this.peerReconcile(sessionExpectation(current));
  }

  // --- Signing in, completed -------------------------------------------------------------------------------------

  #completeAuth<
    S extends z.ZodType,
    Operation extends
      | "sign_in_with_google"
      | "verify_email_login"
      | "verify_google_link",
    Value,
  >(input: {
    attempt: SessionAuthAttemptRef;
    body: Record<string, string>;
    kind: "complete_google_login" | "verify_email_login" | "verify_google_link";
    operation: Operation;
    path: string;
    schema: S;
    unauthorizedCode: SessionOperationErrorCodeFor<Operation>;
    settle: (
      value: z.output<S>
    ) =>
      | { kind: "signed_in"; projection: SessionProjection }
      | { kind: "otp_required"; value: z.output<typeof googleLinkChallenge> };
    value: (snapshot: SignedInSessionSnapshot) => Value;
  }): Effect.Effect<SessionOperationResult<Value, Operation>> {
    const { operation } = input;
    type Result = SessionOperationResult<Value, Operation>;
    return Effect.suspend((): Effect.Effect<Result> => {
      const epoch = this.nextEpoch();
      if (!this.isCurrentAttempt(input.attempt))
        return Effect.succeed(this.failure(operation, "conflict") as Result);
      return this.#locked(
        Effect.gen({ self: this }, function* () {
          const record = yield* this.#ensureSettledRecordForIntent();
          if (
            record.kind !== "authenticating" ||
            record.activeAuthAttemptId !== input.attempt.attemptId ||
            !this.isCurrentAttempt(input.attempt)
          )
            return this.failure(operation, "conflict") as Result;
          const marker = yield* this.#writeInFlight(record, epoch, {
            authAttemptId: input.attempt.attemptId,
            expectedSessionId: "none",
            kind: input.kind,
          });
          const response = yield* this.#request("POST", input.path, "none", {
            ...input.body,
            ...clientMetadata(this.#ports.userAgent),
          });
          if (!response) {
            this.publishIndeterminate("credential_mutation_uncertain", "authenticate");
            return this.failure(operation, "credential_mutation_uncertain") as Result;
          }
          if (response.ok) {
            const value = parsed(response, input.schema);
            if (value === undefined) {
              yield* this.#restoreAfterResponse(marker);
              this.publishIndeterminate("protocol_mismatch", "authenticate");
              return this.failure(operation, "protocol_mismatch") as Result;
            }
            const settled = input.settle(value);
            if (settled.kind === "otp_required") {
              const restored = yield* this.#restoreAfterResponse(marker);
              if (!this.isCurrentAttempt(input.attempt))
                return this.failure(operation, "conflict") as Result;
              const refreshed = yield* this.#writeNext(restored, {
                activeAuthAttemptId: input.attempt.attemptId,
                kind: "authenticating",
                operationEpoch: epoch,
                state: { kind: "absent" },
              });
              this.attempt = {
                attempt: input.attempt,
                challengeId: settled.value.challenge_id,
                email: settled.value.email,
                kind: "google",
                operationEpoch: epoch,
              };
              this.#adopt(refreshed);
              return {
                ok: true,
                value: {
                  attempt: input.attempt,
                  challengeId: settled.value.challenge_id,
                  ...(settled.value.code ? { code: settled.value.code } : {}),
                  email: settled.value.email,
                  status: "otp_required",
                } as Value,
              } as Result;
            }
            const stable = yield* this.#writeNext(
              marker,
              {
                kind: "stable",
                state: { kind: "present", sessionId: settled.projection.session_id },
              },
              marker.cookieGeneration + 1
            );
            this.attempt = undefined;
            this.#adopt(stable);
            const snapshot = this.publishSignedIn(settled.projection);
            this.#publishHint(stable);
            return { ok: true, value: input.value(snapshot) } as Result;
          }
          yield* this.#restoreAfterResponse(marker);
          if (response.status === 401)
            return this.failure(operation, input.unauthorizedCode) as Result;
          if (response.status === 409 && parsed(response, sessionChanged))
            return this.failure(operation, "conflict") as Result;
          return this.failure(
            operation,
            response.status === 403
              ? "account_disabled"
              : response.status === 429
                ? "rate_limited"
                : response.status >= 500
                  ? "provider_unavailable"
                  : "unknown"
          ) as Result;
        })
      ).pipe(
        Effect.catch((fault: Fault) =>
          Effect.sync(() => this.#operationFailure(operation, fault, epoch) as Result)
        )
      );
    });
  }

  // --- Probes and recovery ---------------------------------------------------------------------------------------

  #runProbe(
    record: SettledRecord,
    epoch: number,
    callerExpected: SessionLifecycleExpectation | undefined
  ): Op<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    return Effect.gen({ self: this }, function* () {
      if (
        this.current.phase === "authenticating" ||
        this.current.phase === "signing_out"
      )
        return this.failure("reconcile", "conflict");
      const expectedSessionId = recordSessionId(record);
      if (expectedSessionId === undefined)
        return this.failure("reconcile", "protocol_mismatch");
      const expectedHeader = expectedSessionId ?? "none";
      if (
        callerExpected &&
        !this.#cookieRecordCanReadmitReconcile(record, callerExpected)
      )
        return this.failure("reconcile", "conflict");
      // The current lease stays usable while the probe runs: every product request names the session it expects,
      // so the server refuses it with 409 if the Cookie moved.
      const adoptionBefore = this.#adopted;
      const marker = yield* this.#writeInFlight(record, epoch, {
        expectedSessionId: expectedHeader,
        kind: "reconcile",
      });
      const response = yield* this.#request(
        "GET",
        "/v1/comma/auth/session",
        expectedHeader
      );
      if (!response) {
        yield* this.#restoreAfterResponse(marker);
        if (
          this.isCurrentEpoch(epoch) &&
          !this.#keepSignedInThroughProbeFailure(epoch, adoptionBefore)
        )
          this.publishIndeterminate("session_probe_unavailable", "reconcile");
        return this.failure("reconcile", "network_unavailable");
      }
      if (!this.isCurrentEpoch(epoch)) {
        yield* this.#restoreAfterResponse(marker);
        return this.failure("reconcile", "conflict");
      }
      if (response.ok) {
        const projection = parsed(response, sessionProjection);
        if (
          !projection ||
          expectedSessionId === null ||
          projection.session_id !== expectedSessionId
        ) {
          yield* this.#restoreAfterResponse(marker);
          if (this.isCurrentEpoch(epoch))
            this.publishIndeterminate("protocol_mismatch", "reconcile");
          return this.failure("reconcile", "protocol_mismatch");
        }
        const stable = yield* this.#writeNext(marker, {
          kind: "stable",
          state: { kind: "present", sessionId: projection.session_id },
        });
        this.#adopt(stable);
        return { ok: true as const, value: this.publishSignedIn(projection) };
      }
      if (response.status === 401 && parsed(response, unauthorized)) {
        const nextGeneration =
          expectedSessionId === null
            ? marker.cookieGeneration
            : marker.cookieGeneration + 1;
        const stable = yield* this.#writeNext(
          marker,
          { kind: "stable", state: { kind: "absent" } },
          nextGeneration
        );
        this.#adopt(stable);
        // Absence confirmed (another context's hint, a focus): why the person was signed out stays what it was.
        const before = this.current;
        const snapshot = this.publishSignedOut(
          expectedSessionId !== null
            ? "unauthorized"
            : before.phase === "signed_out"
              ? before.reason
              : "no_session"
        );
        if (nextGeneration !== marker.cookieGeneration) this.#publishHint(stable);
        return { ok: true as const, value: snapshot };
      }
      if (response.status === 409 && parsed(response, sessionChanged)) {
        const restored = yield* this.#restoreAfterResponse(marker);
        if (!this.isCurrentEpoch(epoch)) return this.failure("reconcile", "conflict");
        return yield* this.#rebindToCurrentCookie(restored, epoch);
      }
      if (isProtocolError(response)) {
        yield* this.#restoreAfterResponse(marker);
        if (this.isCurrentEpoch(epoch))
          this.publishIndeterminate("protocol_mismatch", "reconcile");
        return this.failure("reconcile", "protocol_mismatch");
      }
      yield* this.#restoreAfterResponse(marker);
      if (
        this.isCurrentEpoch(epoch) &&
        !this.#keepSignedInThroughProbeFailure(epoch, adoptionBefore)
      )
        this.publishIndeterminate("session_probe_unavailable", "reconcile");
      return this.failure("reconcile", "session_probe_unavailable");
    });
  }

  /** A signed-in session whose lease is still given keeps its view when a probe cannot reach the server, and is probed again in the background. */
  #keepSignedInThroughProbeFailure(
    epoch: number,
    adoptionBefore: Adopted | undefined
  ): boolean {
    if (
      !this.isCurrentEpoch(epoch) ||
      this.current.phase !== "signed_in" ||
      !adoptionBefore
    )
      return false;
    const adoptionAfter = this.#adopted;
    this.#adopted = adoptionBefore;
    if (!this.productOpen()) {
      this.#adopted = adoptionAfter;
      return false;
    }
    this.sync();
    this.scheduleBackgroundReconcile();
    return true;
  }

  #runRecovery(
    initial: RecoveringRecord,
    epoch: number
  ): Op<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    return Effect.gen({ self: this }, function* () {
      let record = initial;
      const now = this.now();
      const { ticket } = record;
      if (
        ticket.attemptsStarted >= ticket.maxAttempts ||
        now >= ticket.deadlineAtEpochMs ||
        ticket.progress.phase === "exhausted" ||
        (ticket.progress.phase === "backoff" &&
          now < ticket.progress.nextAttemptNotBeforeEpochMs)
      ) {
        if (this.isCurrentEpoch(epoch)) {
          this.#adopt(record);
          this.publishIndeterminate("session_probe_unavailable", "reconcile");
        }
        return this.failure("reconcile", "session_probe_unavailable");
      }
      record = yield* this.#writeNext(record, {
        kind: "recovering",
        ticket: {
          ...ticket,
          attemptsStarted: ticket.attemptsStarted + 1,
          progress: {
            ownerNonce: this.randomId(),
            phase: "in_flight",
            startedAtEpochMs: now,
          },
        },
      });
      this.#adopt(record);
      const expectation = record.ticket.expectation;
      const expected =
        expectation.kind === "unknown_rebind" ? "unknown" : expectation.sessionId;
      const response = yield* this.#request("GET", "/v1/comma/auth/session", expected);
      if (!response) {
        this.#adopt(yield* this.#settleRecoveryFailure(record, "network_unavailable"));
        if (this.isCurrentEpoch(epoch))
          this.publishIndeterminate("session_probe_unavailable", "reconcile");
        return this.failure("reconcile", "network_unavailable");
      }
      const nextGeneration =
        expectation.kind === "unknown_rebind"
          ? record.cookieGeneration + 1
          : record.cookieGeneration;
      if (response.ok) {
        const projection = parsed(response, sessionProjection);
        if (
          !projection ||
          (expectation.kind === "exact_session" &&
            projection.session_id !== expectation.sessionId)
        ) {
          this.#adopt(yield* this.#settleRecoveryFailure(record, "protocol_mismatch"));
          if (this.isCurrentEpoch(epoch))
            this.publishIndeterminate("protocol_mismatch", "reconcile");
          return this.failure("reconcile", "protocol_mismatch");
        }
        const stable = yield* this.#writeNext(
          record,
          {
            kind: "stable",
            state: { kind: "present", sessionId: projection.session_id },
          },
          nextGeneration
        );
        this.#adopt(stable);
        const snapshot = this.publishSignedIn(projection);
        this.#publishHint(stable);
        return { ok: true as const, value: snapshot };
      }
      if (response.status === 401 && parsed(response, unauthorized)) {
        const stable = yield* this.#writeNext(
          record,
          { kind: "stable", state: { kind: "absent" } },
          nextGeneration
        );
        this.#adopt(stable);
        const snapshot = this.publishSignedOut("no_session");
        this.#publishHint(stable);
        return { ok: true as const, value: snapshot };
      }
      if (
        response.status === 409 &&
        expectation.kind === "exact_session" &&
        parsed(response, sessionChanged)
      )
        return yield* this.#rebindToCurrentCookie(record, epoch);
      const problem =
        response.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch";
      this.#adopt(yield* this.#settleRecoveryFailure(record, problem));
      if (this.isCurrentEpoch(epoch)) this.publishIndeterminate(problem, "reconcile");
      return this.failure("reconcile", problem);
    });
  }

  /**
   * A 409: the Cookie names another session now (another tab or context signed in, out, or as someone else). Whatever
   * it holds is adopted. Under the lock.
   */
  #rebindToCurrentCookie(
    previous: WebSessionRecord,
    epoch: number
  ): Op<SessionOperationResult<TerminalSessionSnapshot, "reconcile">> {
    return Effect.gen({ self: this }, function* () {
      const recovery = yield* this.#createUnknownRecovery(previous);
      this.#adopt(recovery);
      return yield* this.#runRecovery(recovery, epoch);
    });
  }

  /**
   * The record, made safe to act on. Missing or unreadable: nothing is known of the Cookie (a new authority, an
   * unknown recovery). An operation in flight: its owner is gone without settling it (the lock is ours now, and the
   * core that took it out ended), so the Cookie may hold anything. A recovery attempt in flight: ready again, or
   * exhausted.
   */
  #ensureRecoverableRecord(): Op<WebSessionRecord> {
    return Effect.gen({ self: this }, function* () {
      const read = yield* this.#read();
      if (read.kind !== "valid") return yield* this.#createUnknownRecovery(undefined);
      const record = read.record;
      if (record.kind === "in_flight")
        return yield* this.#createUnknownRecovery(record);
      if (
        record.kind === "recovering" &&
        record.ticket.progress.phase === "in_flight"
      ) {
        const exhausted =
          record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
          this.now() >= record.ticket.deadlineAtEpochMs;
        return yield* this.#writeNext(record, {
          kind: "recovering",
          ticket: {
            ...record.ticket,
            progress: exhausted
              ? { phase: "exhausted", problem: "session_probe_unavailable" }
              : { phase: "ready" },
          },
        });
      }
      return record;
    });
  }

  /** As `#ensureRecoverableRecord`, the person having asked: a used-up ticket is renewed, a backoff skipped. */
  #ensureManualRecoveryRecord(): Op<WebSessionRecord> {
    return Effect.gen({ self: this }, function* () {
      const record = yield* this.#ensureRecoverableRecord();
      if (record.kind !== "recovering") return record;
      const now = this.now();
      const exhausted =
        record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
        now >= record.ticket.deadlineAtEpochMs ||
        record.ticket.progress.phase === "exhausted";
      if (exhausted)
        return yield* this.#writeNext(record, {
          kind: "recovering",
          ticket: {
            attemptsStarted: 0,
            deadlineAtEpochMs: now + RECOVERY_WINDOW_MS,
            expectation: record.ticket.expectation,
            maxAttempts: RECOVERY_MAX_ATTEMPTS,
            progress: { phase: "ready" },
            ticketId: this.randomId(),
          },
        });
      if (record.ticket.progress.phase === "backoff")
        return yield* this.#writeNext(record, {
          kind: "recovering",
          ticket: { ...record.ticket, progress: { phase: "ready" } },
        });
      return record;
    });
  }

  #ensureSettledRecordForIntent(): Op<SettledRecord> {
    return this.#ensureRecoverableRecord().pipe(
      Effect.filterOrFail(
        (record): record is SettledRecord =>
          record.kind === "authenticating" || record.kind === "stable",
        () =>
          new Fault("storage", "The Web Cookie authority is awaiting bounded recovery.")
      )
    );
  }

  #createUnknownRecovery(previous: WebSessionRecord | undefined): Op<RecoveringRecord> {
    return Effect.suspend(() =>
      this.#persist(previous, {
        canonicalApiOrigin: this.origin,
        cookieAuthorityId: this.randomId(),
        cookieGeneration: 0,
        coordinationRevision: 0,
        kind: "recovering",
        schemaVersion: 1,
        ticket: {
          attemptsStarted: 0,
          deadlineAtEpochMs: this.now() + RECOVERY_WINDOW_MS,
          expectation: { kind: "unknown_rebind" },
          maxAttempts: RECOVERY_MAX_ATTEMPTS,
          progress: { phase: "ready" },
          ticketId: this.randomId(),
        },
        writeNonce: this.randomId(),
      })
    ) as Op<RecoveringRecord>;
  }

  #writeExactSessionRecovery(
    previous: WebSessionRecord,
    sessionId: string
  ): Op<RecoveringRecord> {
    return Effect.suspend(() =>
      this.#writeNext(previous, {
        kind: "recovering",
        ticket: {
          attemptsStarted: 0,
          deadlineAtEpochMs: this.now() + RECOVERY_WINDOW_MS,
          expectation: { kind: "exact_session", sessionId },
          maxAttempts: RECOVERY_MAX_ATTEMPTS,
          progress: { phase: "ready" },
          ticketId: this.randomId(),
        },
      })
    );
  }

  #settleRecoveryFailure(
    record: RecoveringRecord,
    problem: "network_unavailable" | "protocol_mismatch" | "session_probe_unavailable"
  ): Op<RecoveringRecord> {
    return Effect.suspend(() => {
      const now = this.now();
      const exhausted =
        record.ticket.attemptsStarted >= record.ticket.maxAttempts ||
        now >= record.ticket.deadlineAtEpochMs;
      return this.#writeNext(record, {
        kind: "recovering",
        ticket: {
          ...record.ticket,
          progress:
            problem === "protocol_mismatch" || exhausted
              ? { phase: "exhausted", problem }
              : {
                  nextAttemptNotBeforeEpochMs: now + RECOVERY_BACKOFF_MS,
                  phase: "backoff",
                  problem,
                },
        },
      });
    });
  }

  #clearAttemptIfCurrent(
    previous: Extract<WebSessionRecord, { kind: "authenticating" }>,
    attemptId: string
  ): Op<void> {
    return Effect.gen({ self: this }, function* () {
      const read = yield* this.#read();
      if (
        read.kind !== "valid" ||
        read.record.kind !== "authenticating" ||
        read.record.cookieAuthorityId !== previous.cookieAuthorityId ||
        read.record.activeAuthAttemptId !== attemptId
      )
        return;
      const stable = yield* this.#writeNext(read.record, {
        kind: "stable",
        state: { kind: "absent" },
      });
      if (this.attempt?.attempt.attemptId === attemptId) {
        this.attempt = undefined;
        this.#adopt(stable);
        this.publishSignedOut("no_session");
      }
    });
  }

  #restoreAfterResponse(marker: InFlightRecord): Op<SettledRecord> {
    return this.#writeNext(marker, marker.prior).pipe(
      Effect.tap((restored) => Effect.sync(() => this.#adopt(restored)))
    ) as Op<SettledRecord>;
  }

  #settleSignedOut(
    marker: InFlightRecord,
    reason: "guest_handoff" | "unauthorized" | "user_signed_out"
  ): Op<SignedOutSessionSnapshot> {
    return Effect.gen({ self: this }, function* () {
      const nextGeneration =
        marker.operation.kind === "sign_out"
          ? marker.cookieGeneration + 1
          : marker.cookieGeneration;
      const stable = yield* this.#writeNext(
        marker,
        { kind: "stable", state: { kind: "absent" } },
        nextGeneration
      );
      this.attempt = undefined;
      this.#adopt(stable);
      const snapshot = this.publishSignedOut(reason);
      this.#publishHint(stable);
      return snapshot;
    });
  }

  #writeInFlight(
    previous: SettledRecord,
    epoch: number,
    operation: InFlightOperation,
    cookieGeneration = previous.cookieGeneration
  ): Op<InFlightRecord> {
    return Effect.suspend(() => {
      const now = this.now();
      return this.#writeNext(
        previous,
        {
          kind: "in_flight",
          operation,
          owner: {
            deadlineAtEpochMs: now + REQUEST_TIMEOUT_MS,
            nonce: this.randomId(),
            operationEpoch: epoch,
            startedAtEpochMs: now,
          },
          prior: settledStateOf(previous),
        },
        cookieGeneration
      );
    });
  }

  #writeNext<B extends RecordBody>(
    previous: WebSessionRecord,
    body: B,
    cookieGeneration = previous.cookieGeneration
  ): Op<Extract<WebSessionRecord, { kind: B["kind"] }>> {
    return Effect.suspend(() =>
      this.#persist(previous, {
        canonicalApiOrigin: previous.canonicalApiOrigin,
        cookieAuthorityId: previous.cookieAuthorityId,
        cookieGeneration,
        coordinationRevision: previous.coordinationRevision + 1,
        schemaVersion: 1,
        writeNonce: this.randomId(),
        ...body,
      })
    ) as Op<Extract<WebSessionRecord, { kind: B["kind"] }>>;
  }

  /** Writes the record to device storage and reads it back: it is what a core started after this one resumes from. */
  #persist(
    previous: WebSessionRecord | undefined,
    next: unknown
  ): Op<WebSessionRecord> {
    const host = this.host;
    const key = this.#storageKey;
    return Effect.gen(function* () {
      const checked = yield* Effect.try({
        try: () => checkedRecord(previous, next),
        catch: (e) => new Fault("storage", e instanceof Error ? e.message : String(e)),
      });
      const encoded = JSON.stringify(checked);
      yield* host.storageSet(key, utf8(encoded));
      const back = yield* host.storageGet(key);
      if (back === null || fromUtf8(back) !== encoded)
        return yield* Effect.fail(
          new Fault("storage", "the session record did not read back")
        );
      return checked;
    }).pipe(
      Effect.mapError((e) =>
        e instanceof Fault
          ? e
          : new Fault("storage", e instanceof Error ? e.message : String(e))
      )
    );
  }

  #read(): Op<RecordRead> {
    return this.host.storageGet(this.#storageKey).pipe(
      Effect.map((raw) => readRecord(raw === null ? null : fromUtf8(raw), this.origin)),
      Effect.mapError((e) => new Fault("storage", e.message))
    );
  }

  /** The origin's Cookie lock (shared with the page adapter): waited for at most 2 s, held while `work` runs. */
  #locked<A>(work: Op<A>): Op<A> {
    const ports = this.#ports;
    const name = this.#lockName;
    return Effect.uninterruptibleMask((restore) =>
      Effect.gen(function* () {
        const release = yield* restore(
          ports.lock(name).pipe(
            Effect.mapError((e) =>
              e instanceof HostUnsupported
                ? new Fault(
                    "unsupported",
                    "Web Locks is required for the Cookie Session authority."
                  )
                : new Fault("other", e.message)
            ),
            Effect.timeoutOrElse({
              duration: LOCK_ACQUIRE_TIMEOUT_MS,
              orElse: () =>
                Effect.fail(new Fault("lock_timeout", "Web Session lock timed out.")),
            })
          )
        );
        return yield* restore(work).pipe(Effect.ensuring(Effect.sync(release)));
      })
    ).pipe(
      // A bug or a host port that threw (a rejected transition, random bytes refused) fails the operation as one
      // that could not run, as the adapter's try/catch around its lock did: the failure handling settles the snapshot.
      Effect.catchDefect((defect) => Effect.fail(new Fault("other", describe(defect))))
    );
  }

  /** An auth request, given up after 8 s (its body read included): null when it got no answer. */
  #request(
    method: "GET" | "POST",
    path: string,
    expectedSessionId: string,
    body?: Record<string, unknown>
  ): Effect.Effect<AuthResponse | null> {
    return Effect.suspend(() =>
      this.#authFetch({
        method,
        path,
        headers: body
          ? [
              ["accept", "application/json"],
              ["content-type", "application/json"],
            ]
          : [["accept", "application/json"]],
        body: body ? utf8(JSON.stringify(body)) : null,
        expectedSessionId,
      })
    ).pipe(
      Effect.timeoutOrElse({
        duration: REQUEST_TIMEOUT_MS,
        orElse: () => Effect.fail(new HostError("the request took too long")),
      }),
      Effect.map((response): AuthResponse | null => ({
        ok: response.status >= 200 && response.status < 300,
        status: response.status,
        body: jsonBody(response.body),
      })),
      Effect.orElseSucceed(() => null)
    );
  }

  /** A fresh guest challenge, solved. Neither step has side effects. */
  #solveGuestChallenge(): Effect.Effect<
    | { ok: true; value: { challenge: string; nonce: string } }
    | { ok: false; code: SessionOperationErrorCodeFor<"start_guest_session"> }
  > {
    return Effect.gen({ self: this }, function* () {
      const response = yield* this.#request("GET", "/v1/comma/auth/guest", "none");
      if (!response)
        return { ok: false as const, code: "network_unavailable" as const };
      if (!response.ok)
        return { ok: false as const, code: guestStartRefusal(response) };
      const availability = parsed(response, guestAvailabilityRemoteSchema);
      if (!availability)
        return { ok: false as const, code: "protocol_mismatch" as const };
      if (!availability.enabled)
        return { ok: false as const, code: "unsupported" as const };
      if (!availability.pow)
        return { ok: false as const, code: "protocol_mismatch" as const };
      const solved = yield* Effect.result(
        solveGuestPow(
          availability.pow.challenge,
          availability.pow.difficulty,
          (inputs) => this.#ports.sha256(inputs)
        )
      );
      if (Result.isFailure(solved) || solved.success === null)
        return { ok: false as const, code: "unknown" as const };
      return { ok: true as const, value: solved.success };
    });
  }

  // --- Publishing ----------------------------------------------------------------------------------------------

  /** Keeps where this authority is for the core that runs next (best effort: without it, that core starts anew). */
  protected override onPublished(): void {
    const value = utf8(JSON.stringify(this.resumeRecord()));
    if (!this.closed)
      this.runner.fork(Effect.ignore(this.host.storageSet(this.#authorityKey, value)));
  }

  #adopt(record: WebSessionRecord): void {
    this.#adopted = {
      cookieAuthorityId: record.cookieAuthorityId,
      cookieGeneration: record.cookieGeneration,
      coordinationRevision: record.coordinationRevision,
      sessionId: recordSessionId(record),
    };
    this.sync();
  }

  // --- Guest imports ---------------------------------------------------------------------------------------------

  /**
   * Redeems a guest claim Cookie a handoff left once a registered session is current. A failure that may pass keeps
   * the marker for the next sign-in or probe; a refused or expired claim clears it.
   */
  #redeemGuestImport(): void {
    if (this.#guestImport !== null) return;
    const lease = this.session.lease();
    if (!lease) return;
    // Declared first: the fiber may end before `fork` returns (nothing to redeem, read at once).
    let fiber: Fiber.Fiber<unknown, unknown> | null = null;
    let ended = false;
    fiber = this.runner.fork(
      Effect.gen({ self: this }, function* () {
        const marker = yield* this.#readMarker();
        if (!marker) return;
        if (marker.expiresAtEpochSeconds * 1_000 <= this.now()) {
          yield* this.#clearMarker();
          return;
        }
        // Cookie transport: the server reads and clears the claim Cookie.
        const response = yield* this.#request(
          "POST",
          "/v1/comma/guest-imports",
          lease.sessionId,
          {}
        );
        if (!response) return;
        if (response.ok) {
          yield* this.#clearMarker();
          if (parsed(response, guestImportAnswer) && !this.closed) {
            this.guestImports += 1;
            this.sync();
          }
          return;
        }
        if (response.status === 404) yield* this.#clearMarker();
      }).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            ended = true;
            if (fiber !== null && this.#guestImport === fiber) this.#guestImport = null;
          })
        )
      )
    );
    if (!ended) this.#guestImport = fiber;
  }

  /**
   * A guest import the page adapter noted (its localStorage marker, which a worker cannot read), handed over once
   * when the page moves to the core: kept unless expired or an import noted here lasts longer, and redeemed at once
   * when a registered account is signed in. True when it is kept.
   */
  handOverGuestImport(expiresAtEpochSeconds: number): Effect.Effect<boolean> {
    return Effect.gen({ self: this }, function* () {
      if (expiresAtEpochSeconds * 1_000 <= this.now()) return false;
      const kept = yield* this.#readMarker();
      if (kept && kept.expiresAtEpochSeconds >= expiresAtEpochSeconds) return true;
      yield* this.#writeMarker(expiresAtEpochSeconds);
      const current = this.current;
      if (
        current.phase === "signed_in" &&
        sessionPrincipalKind(current.principal) !== "guest"
      )
        this.#redeemGuestImport();
      return true;
    });
  }

  #readMarker(): Effect.Effect<z.output<typeof guestImportMarker> | undefined> {
    return this.host.storageGet(this.#markerKey).pipe(
      Effect.map((raw) => {
        if (!raw || raw.length === 0) return undefined;
        try {
          const out = guestImportMarker.safeParse(JSON.parse(fromUtf8(raw)));
          return out.success ? out.data : undefined;
        } catch {
          return undefined;
        }
      }),
      Effect.orElseSucceed(() => undefined)
    );
  }

  /** Without storage the claim Cookie simply expires unredeemed. */
  #writeMarker(expiresAtEpochSeconds: number): Effect.Effect<void> {
    return this.host
      .storageSet(this.#markerKey, utf8(JSON.stringify({ expiresAtEpochSeconds })))
      .pipe(Effect.ignore);
  }

  /** A stale marker is dropped by the next refused redemption. */
  #clearMarker(): Effect.Effect<void> {
    return this.host.storageDelete(this.#markerKey).pipe(Effect.ignore);
  }

  // --- Other contexts --------------------------------------------------------------------------------------------

  #publishHint(record: WebSessionRecord): void {
    const hint: Hint = {
      canonicalApiOrigin: this.origin,
      cookieAuthorityId: record.cookieAuthorityId,
      cookieGeneration: record.cookieGeneration,
      coordinationRevision: record.coordinationRevision,
      kind: "session_maybe_changed",
      schemaVersion: 1,
      senderId: this.#senderId,
    };
    this.#channel.post(hint);
  }

  /** Another context (a page still on the adapter) may have changed the Cookie. */
  #hint(value: unknown): void {
    const hint = value as Partial<Hint> | null;
    if (
      this.closed ||
      typeof hint !== "object" ||
      hint === null ||
      hint.kind !== "session_maybe_changed" ||
      hint.schemaVersion !== 1 ||
      hint.canonicalApiOrigin !== this.origin ||
      hint.senderId === this.#senderId
    )
      return;
    const current = this.current;
    const expected =
      current.phase === "signed_in" || current.phase === "signed_out"
        ? sessionExpectation(current)
        : undefined;
    // The record is the core's own (the adapter's is in localStorage, out of a worker's reach), so the hint says
    // nothing the record could confirm: the server is asked. A record that cannot be read ends the lease, as the
    // adapter's did.
    this.fork(
      this.#read().pipe(
        Effect.match({
          onFailure: () =>
            this.publishIndeterminate("credential_store_unavailable", "reconcile"),
          onSuccess: (read) => {
            if (read.kind === "valid") this.peerReconcile(expected);
          },
        })
      )
    );
  }

  // --- Fencing ---------------------------------------------------------------------------------------------------

  #canCommitAuthAttempt(
    record: SettledRecord,
    expected: SessionAbsenceExpectation
  ): boolean {
    return (
      this.canStartAuthentication(expected) &&
      this.#adopted?.cookieAuthorityId === record.cookieAuthorityId &&
      this.#adopted.cookieGeneration === record.cookieGeneration &&
      recordSessionId(record) === null
    );
  }

  #recordMatchesCurrentLease(record: SettledRecord, sessionId: string): boolean {
    const adopted = this.#adopted;
    return (
      record.kind === "stable" &&
      record.state.kind === "present" &&
      record.state.sessionId === sessionId &&
      adopted?.cookieAuthorityId === record.cookieAuthorityId &&
      adopted.cookieGeneration === record.cookieGeneration
    );
  }

  #recordMatchesLease(
    record: SettledRecord,
    lease: SessionLease,
    cookie: CookieIdentity
  ): boolean {
    return (
      record.kind === "stable" &&
      record.state.kind === "present" &&
      record.state.sessionId === lease.sessionId &&
      record.cookieAuthorityId === cookie.cookieAuthorityId &&
      record.cookieGeneration === cookie.cookieGeneration
    );
  }

  /** Whether `lease` is the one requests go out with now (the same object: a gate opened anew is another). */
  #isCurrentProductLease(lease: SessionLease): boolean {
    return this.productOpen() && this.session.lease() === lease;
  }

  /** Whether `lease` names the current session and Cookie (its gate may have closed since). */
  #isCurrentProductLeaseIdentity(lease: SessionLease, cookie: CookieIdentity): boolean {
    const current = sessionProductLease(this.current);
    const adopted = this.#adopted;
    return (
      current !== undefined &&
      current.authorityInstanceId === lease.authorityInstanceId &&
      current.generation === lease.generation &&
      current.sessionId === lease.sessionId &&
      current.audience === lease.audience &&
      adopted?.cookieAuthorityId === cookie.cookieAuthorityId &&
      adopted.cookieGeneration === cookie.cookieGeneration
    );
  }

  #cookieRecordCanReadmitReconcile(
    record: WebSessionRecord,
    callerExpected: SessionLifecycleExpectation
  ): boolean {
    if (!this.localExpectationMatches(callerExpected)) return false;
    const adopted = this.#adopted;
    if (!adopted) return this.current.phase === "initializing";
    if (
      record.cookieAuthorityId === adopted.cookieAuthorityId &&
      record.cookieGeneration === adopted.cookieGeneration
    )
      return true;
    return (
      record.cookieAuthorityId !== adopted.cookieAuthorityId ||
      record.cookieGeneration > adopted.cookieGeneration
    );
  }

  // --- Failures --------------------------------------------------------------------------------------------------

  #lifecycleFailure(
    fault: Fault,
    epoch: number
  ): SessionOperationResult<never, "reconcile"> {
    if (
      fault.kind === "lock_timeout" &&
      this.#keepSignedInThroughProbeFailure(epoch, this.#adopted)
    )
      return this.failure("reconcile", "network_unavailable");
    if (this.isCurrentEpoch(epoch))
      this.publishIndeterminate(
        fault.kind === "storage"
          ? "credential_store_unavailable"
          : fault.kind === "unsupported"
            ? "protocol_mismatch"
            : "session_probe_unavailable",
        this.current.phase === "initializing" ? "initialize" : "reconcile"
      );
    return this.failure("reconcile", faultCode(fault) as "unknown");
  }

  #operationFailure<Operation extends SessionOperationName>(
    operation: Operation,
    fault: Fault,
    epoch: number
  ): SessionOperationResult<never, Operation> {
    if (
      this.isCurrentEpoch(epoch) &&
      (fault.kind === "storage" ||
        fault.kind === "unsupported" ||
        (operation === "sign_out" && fault.kind === "lock_timeout"))
    )
      this.publishIndeterminate(
        fault.kind === "storage"
          ? "credential_store_unavailable"
          : fault.kind === "unsupported"
            ? "protocol_mismatch"
            : "session_probe_unavailable",
        operation === "sign_out" ? "sign_out" : "authenticate"
      );
    if (fault.kind === "other" && this.isCurrentEpoch(epoch))
      this.unstick(operation === "sign_out" ? "sign_out" : "authenticate");
    return {
      error: createSessionOperationErrorOrUnknown(
        operation,
        faultCode(fault),
        this.current
      ),
      ok: false,
    };
  }

  // --- Plumbing --------------------------------------------------------------------------------------------------
}

function describe(defect: unknown): string {
  return defect instanceof Error ? defect.message : String(defect);
}

function faultCode(fault: Fault): SessionOperationErrorCode {
  return fault.kind === "unsupported"
    ? "unsupported"
    : fault.kind === "storage"
      ? "credential_store_unavailable"
      : fault.kind === "lock_timeout"
        ? "network_unavailable"
        : "unknown";
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
