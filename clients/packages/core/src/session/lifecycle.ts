// The session lifecycle's state machine as the web and Electron share it. What a session lifecycle publishes and how:
// the phases, the snapshot's generation and revision rules, the product lease it gives (`Session.applyLifecycle`),
// the sign-in under way and the epochs that fence what an older call finds, the expectations a call must name, the
// re-probes after a probe that could not reach the server (1, 3, 10, 30 s, on the core's Clock), one peer reconcile
// per expectation, the authority's place kept across a core's restart, and how a failure or a defect settles the
// snapshot. What differs is where the credential is and how it changes: the web's Cookie (web-lifecycle.ts: the Web
// Lock, the Cookie record in device storage, recovery tickets, hints to other contexts) and Electron's bearer in Main
// (electron-lifecycle.ts: Main's credential store by reference, its gate, its Google window). Each is a subclass with
// its host's ports; neither has a copy of what is here.
import {
  createSessionOperationError,
  createSessionOperationErrorOrUnknown,
  createSessionProblem,
  mergeSessionSnapshot,
  sessionExpectation,
  sessionProductLease,
  type SessionAbsenceExpectation,
  type SessionAuthAttemptRef,
  type SessionCleanup,
  type SessionLifecycleExpectation,
  type SessionLifecycleSnapshot,
  type SessionOperationErrorCodeFor,
  type SessionOperationName,
  type SessionOperationResult,
  type SignedInSessionSnapshot,
  type SignedOutSessionSnapshot,
  type TerminalSessionSnapshot,
} from "@comma/session-contract";
import type { Runner } from "@comma/core-kernel";
import { Effect, type Fiber } from "effect";
import type {
  SessionAttempt,
  SessionEmailChallenge,
  SessionEmailCooldown,
} from "../contract.ts";
import type { Host, SessionAuthorityResume } from "../host.ts";
import type { Session } from "../session.ts";
import type { SessionProjection } from "./web-auth.ts";

/**
 * Background re-probes after a signed-in probe could not reach the server. After the last one the session stays
 * signed in; product requests still name the session they expect, so a real 401 or 409 shows.
 */
export const BACKGROUND_RECONCILE_MS = [1_000, 3_000, 10_000, 30_000] as const;

/**
 * A connection recovery burst: tries at these delays (the first at once), then stops until asked again (a retry, the
 * network back). One burst for the whole core, never per window.
 */
export const CONNECTION_RECOVERY_MS = [0, 1_000, 3_000, 10_000, 30_000] as const;

/** The checks of an emailed code. */
type VerifyOperation =
  | "verify_email_login"
  | "verify_google_link"
  | "verify_apple_link";

/** Failures of a code's check that did not get the server's answer about the code: the same code may be sent again. */
const sameCodeRetry: ReadonlySet<string> = new Set([
  "network_unavailable",
  "provider_unavailable",
  "unknown",
]);

/** How soon another code may be sent when the server does not say. */
export const EMAIL_RESEND_DELAY_MS = 60_000;

/** A sign-in under way: its ref, which kind, the epoch it was made in, and the code it waits for. */
export type LifecycleAttempt = {
  attempt: SessionAuthAttemptRef;
  kind: "email" | "google" | "apple" | "guest";
  operationEpoch: number;
  challengeId?: string;
  email?: string;
  /** When the emailed code stops working, and when another may be sent (the core's clock). */
  expiresAt?: number;
  resendAt?: number;
};

type Body<P extends SessionLifecycleSnapshot["phase"]> = Omit<
  Extract<SessionLifecycleSnapshot, { phase: P }>,
  "authority" | "cleanup" | "contractVersion" | "generation" | "revision"
>;

export type SnapshotBody =
  | Body<"signed_in">
  | Body<"signed_out">
  | Body<"authenticating" | "initializing" | "invalidating" | "signing_out">
  | Body<"indeterminate">;

export type ProblemCode =
  | "credential_mutation_uncertain"
  | "credential_store_unavailable"
  | "credential_store_unreadable"
  | "protocol_mismatch"
  | "session_probe_unavailable";

export type ProblemOperation =
  | "authenticate"
  | "initialize"
  | "invalidate"
  | "reconcile"
  | "sign_out";

export type ReconcileReason = "startup" | "focus" | "manual_retry" | "peer_mutation";

export type ReconcileResult = SessionOperationResult<
  TerminalSessionSnapshot,
  "reconcile"
>;

export interface LifecycleDeps {
  host: Host;
  runner: Runner;
  session: Session;
  now(): number;
}

export abstract class SessionLifecycle<
  Attempt extends LifecycleAttempt = LifecycleAttempt,
> {
  /** This authority's id: a new core's own, until it continues the one before it (`resumeFrom`). */
  authorityInstanceId: string;
  protected readonly host: Host;
  protected readonly runner: Runner;
  protected readonly session: Session;
  protected readonly now: () => number;
  protected current: SessionLifecycleSnapshot;
  /** What the snapshot says of the credentials still to revoke (Electron's store; the web has none). */
  protected cleanup: SessionCleanup = { revocation: "idle" };
  protected attempt: Attempt | undefined;
  protected epoch = 0;
  /** Whether the product lease is given: closed the moment a lease is refused or the session is in doubt. */
  protected gateOpen = false;
  /** Counted up each time the gate opens anew: a new lease, even for the same session. */
  protected gateSeq = 0;
  /** Guest chats imported since the core started (the web's). */
  protected guestImports = 0;
  protected closed = false;
  /** The session the core before this one gave a lease for: found again, its lease goes on (no new generation). */
  #resumedSessionId: string | null | undefined;
  #background: Fiber.Fiber<unknown, unknown> | null = null;
  #backgroundAttempt = 0;
  /** The peer reconcile queued or running (its expectation), if one is. */
  #peerKey: string | null = null;
  /** An address the server told to wait before another code is requested, and until when. */
  #cooldown: { email: string; until: number } | undefined;
  /** The connection recovery burst under way (its fiber), or spent (`exhausted`): null while none is needed. */
  #recovery: {
    fiber: Fiber.Fiber<unknown, unknown> | null;
    exhausted: boolean;
  } | null = null;
  /** How many windows show the recovery (`sessionRecovery`): a burst runs only while one does. */
  #recoveryWatchers = 0;
  #recoveryShown: "trying" | "exhausted" | null = null;
  readonly #recoveryListeners = new Set<() => void>();
  /** Wakes the snapshot when a countdown it shows moves to its next second. */
  #countdown: Fiber.Fiber<unknown, unknown> | null = null;

  constructor(
    deps: LifecycleDeps,
    kind: "web_cookie" | "electron_main" | "android_keystore" | "swiftui_keychain"
  ) {
    this.host = deps.host;
    this.runner = deps.runner;
    this.session = deps.session;
    this.now = deps.now;
    this.authorityInstanceId = this.randomId();
    this.current = {
      authority: { authorityInstanceId: this.authorityInstanceId, kind },
      cleanup: { revocation: "idle" },
      contractVersion: 1,
      generation: 0,
      phase: "initializing",
      principal: null,
      revision: 0,
      session: null,
    };
  }

  snapshot(): SessionLifecycleSnapshot {
    return this.current;
  }

  /** What the session is expected to be now, for a check of it (none while it is being found out). */
  expectation(): SessionLifecycleExpectation | undefined {
    const current = this.current;
    if (current.phase === "signed_in" || current.phase === "signed_out")
      return sessionExpectation(current);
    if (current.phase !== "indeterminate") return undefined;
    const sessionId = this.indeterminateSessionId();
    if (sessionId === undefined) return undefined;
    if (sessionId === null)
      return {
        authorityInstanceId: this.authorityInstanceId,
        expectedSessionId: null,
        generation: current.generation,
      };
    return {
      authorityInstanceId: this.authorityInstanceId,
      expectedAudience: this.audience(),
      expectedSessionId: sessionId,
      generation: current.generation,
    };
  }

  abstract reconcile(input: {
    expected?: SessionLifecycleExpectation;
    reason: ReconcileReason;
  }): Effect.Effect<ReconcileResult>;

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.cancelBackground();
    if (this.#countdown !== null) this.runner.interrupt(this.#countdown);
    this.#countdown = null;
    this.#stopRecovery();
  }

  /** Finds the session out again (a retry, or a step of a recovery burst). */
  abstract recover(): Effect.Effect<void>;

  /**
   * A person asks to try again, or the network is back: a connection that needs recovering, shown by a window, starts
   * a new burst; otherwise the session is found out again once.
   */
  retryConnection(): Effect.Effect<void> {
    return Effect.suspend(() => {
      // No window shows a recovery: this is a single retry.
      if (!this.#needsRecovery() || this.#recoveryWatchers === 0) return this.recover();
      this.#stopRecovery();
      this.sync();
      return Effect.void;
    });
  }

  /** The session cannot be used for now, and finding it out again may help: the product waits on a recovery. */
  #needsRecovery(): boolean {
    const current = this.current;
    if (this.closed) return false;
    if (current.phase === "indeterminate")
      // A failed sign-out is never recovered silently: a probe that succeeds would sign the person back in.
      return current.problem.retryable && current.problem.operation !== "sign_out";
    return current.phase === "signed_in" && this.gateKey() === null;
  }

  #stopRecovery(): void {
    if (this.#recovery?.fiber) this.runner.interrupt(this.#recovery.fiber);
    this.#recovery = null;
  }

  /** A window shows the recovery: while one does, the core recovers the connection (returns: it stopped showing). */
  watchRecovery(): () => void {
    this.#recoveryWatchers += 1;
    this.sync();
    let watching = true;
    return () => {
      if (!watching) return;
      watching = false;
      this.#recoveryWatchers -= 1;
      this.sync();
    };
  }

  /** The recovery as a window shows it: under way, spent, or none needed. */
  recoveryState(): "trying" | "exhausted" | null {
    return this.#recovery ? (this.#recovery.exhausted ? "exhausted" : "trying") : null;
  }

  /** Told each time `recoveryState` changes. */
  onRecovery(listener: () => void): () => void {
    this.#recoveryListeners.add(listener);
    return () => void this.#recoveryListeners.delete(listener);
  }

  /**
   * Starts a recovery burst when one is needed, a window shows it, and none is under way or spent; ends it when none
   * is needed or shown.
   */
  #watchRecovery(): void {
    if (!this.#needsRecovery() || this.#recoveryWatchers === 0) {
      this.#stopRecovery();
      return;
    }
    if (this.#recovery !== null) return;
    const recovery: {
      fiber: Fiber.Fiber<unknown, unknown> | null;
      exhausted: boolean;
    } = {
      fiber: null,
      exhausted: false,
    };
    this.#recovery = recovery;
    recovery.fiber = this.runner.fork(
      Effect.gen({ self: this }, function* () {
        for (const delay of CONNECTION_RECOVERY_MS) {
          yield* Effect.sleep(delay);
          yield* Effect.exit(this.recover());
          if (this.#recovery !== recovery || !this.#needsRecovery()) return;
        }
        recovery.fiber = null;
        recovery.exhausted = true;
        this.sync();
      })
    );
  }

  /** Asks the server to email `input.email` a code. */
  protected abstract requestEmailChallenge(input: {
    email: string;
    expected: SessionAbsenceExpectation;
  }): Effect.Effect<
    SessionOperationResult<SessionEmailChallenge, "request_email_login">
  >;

  /**
   * Emails a code, on the core's clock: another for the same address waits out the server's resend delay, and an
   * address the server refused for a while waits out its retry-after (`rate_limited`, no request). The address of the
   * code under way, while that code still works, goes back to it without a request (`resumed`) unless `resend` asks
   * for another.
   */
  requestEmailLogin(input: {
    email: string;
    expected: SessionAbsenceExpectation;
    resend?: true | undefined;
  }): Effect.Effect<
    SessionOperationResult<SessionEmailChallenge, "request_email_login">
  > {
    return Effect.suspend(() => {
      const email = input.email.trim().toLowerCase();
      const resumable = this.#resumableEmail(email, this.now());
      if (resumable && !input.resend) {
        const resumed: SessionOperationResult<
          SessionEmailChallenge,
          "request_email_login"
        > = {
          ok: true,
          value: {
            attempt: resumable.attempt,
            challengeId: resumable.challengeId,
            resumed: true,
          },
        };
        return Effect.succeed(resumed);
      }
      const wait = this.#emailWait(email, this.now());
      if (wait > 0)
        return Effect.succeed(
          this.failureOrUnknown("request_email_login", "rate_limited", wait)
        );
      return this.requestEmailChallenge({
        email: input.email,
        expected: input.expected,
      }).pipe(
        Effect.tap((result) =>
          Effect.sync(() => {
            const now = this.now();
            if (result.ok) {
              this.#cooldown = undefined;
              const attempt = this.attempt;
              if (attempt?.challengeId === result.value.challengeId) {
                if (result.value.expiresInSeconds !== undefined)
                  attempt.expiresAt = now + result.value.expiresInSeconds * 1_000;
                attempt.resendAt =
                  now +
                  (result.value.resendAfterSeconds !== undefined
                    ? result.value.resendAfterSeconds * 1_000
                    : EMAIL_RESEND_DELAY_MS);
              }
            } else if (result.error.retryAfterMs) {
              this.#cooldown = { email, until: now + result.error.retryAfterMs };
            }
            this.sync();
          })
        )
      );
    });
  }

  /**
   * Checks an emailed code (`run`) once: a code the server refused for the challenge (`invalid_challenge`) answers
   * that again without a request, and the code of a check that did not reach an answer (`sameCodeRetry`) may be sent
   * again. The attempt's challenge says which (`retrySameCode`). Kept in memory, for the attempt under way.
   */
  verifyCode<Operation extends VerifyOperation>(
    operation: Operation,
    input: { challengeId: string; code: string },
    run: Effect.Effect<SessionOperationResult<SignedInSessionSnapshot, Operation>>
  ): Effect.Effect<SessionOperationResult<SignedInSessionSnapshot, Operation>> {
    return Effect.suspend(() => {
      const checked = this.#checked.get(input.challengeId);
      if (checked?.refused.has(input.code))
        return Effect.succeed(this.failureOrUnknown(operation, "invalid_challenge"));
      return run.pipe(
        Effect.tap((result) =>
          Effect.sync(() => {
            if (result.ok) {
              this.#checked.delete(input.challengeId);
              return;
            }
            const entry = this.#checked.get(input.challengeId) ?? {
              refused: new Set<string>(),
              retrySameCode: false,
            };
            if (result.error.code === "invalid_challenge")
              entry.refused.add(input.code);
            entry.retrySameCode = sameCodeRetry.has(result.error.code);
            this.#checked.set(input.challengeId, entry);
            this.sync();
          })
        )
      );
    });
  }

  /** The codes checked for each challenge (`verifyCode`). */
  readonly #checked = new Map<
    string,
    { refused: Set<string>; retrySameCode: boolean }
  >();

  /** The emailed code under way for `email`, while it still works: a request for the address goes back to it. */
  #resumableEmail(
    email: string,
    now: number
  ): (LifecycleAttempt & { challengeId: string }) | undefined {
    const attempt = this.attempt;
    return attempt?.kind === "email" &&
      attempt.challengeId !== undefined &&
      attempt.email?.trim().toLowerCase() === email &&
      !(attempt.expiresAt !== undefined && attempt.expiresAt <= now)
      ? { ...attempt, challengeId: attempt.challengeId }
      : undefined;
  }

  /** How long `email` must wait before another code is requested (0: none). */
  #emailWait(email: string, now: number): number {
    const attempt = this.attempt;
    const resendAt =
      attempt?.kind === "email" &&
      attempt.challengeId &&
      attempt.email?.trim().toLowerCase() === email
        ? (attempt.resendAt ?? 0)
        : 0;
    const until = this.#cooldown?.email === email ? this.#cooldown.until : 0;
    return Math.max(0, resendAt - now, until - now);
  }

  // --- Hooks ---------------------------------------------------------------------------------------------------

  /** The audience the authority's sessions are for. */
  protected abstract audience(): string;

  /**
   * Which session the credential is known to name while the snapshot is undecided (undefined: not known), so a
   * retry can name it. None by default.
   */
  protected indeterminateSessionId(): string | null | undefined {
    return undefined;
  }

  /** Whether the credential for the signed-in session `sessionId` is the one held (the web: the Cookie adopted). */
  protected credentialHeld(_sessionId: string): boolean {
    return true;
  }

  /** The gate closed (a lease refused, the session in doubt): what runs under the lease stops. */
  protected onGateClosed(): void {}

  /** A registered (not guest) session was published. */
  protected onSignedIn(_guest: boolean): void {}

  /** Keeps where this authority is for the core that runs next (best effort). */
  protected onPublished(): void {}

  // --- Resuming ------------------------------------------------------------------------------------------------

  /**
   * Continues the authority of the core that ran before: the same id, and its generation and revision from where they
   * were. Only before anything was published: a call that came first keeps this core's own.
   */
  protected resumeFrom(saved: SessionAuthorityResume): void {
    if (this.current.revision !== 0) return;
    this.authorityInstanceId = saved.authorityInstanceId;
    this.#resumedSessionId = saved.sessionId;
    // One generation before a lease the core had: finding the same session again issues it at its generation.
    this.current = {
      ...this.current,
      authority: {
        authorityInstanceId: saved.authorityInstanceId,
        kind: this.current.authority.kind,
      },
      generation:
        saved.sessionId === null ? saved.generation : Math.max(0, saved.generation - 1),
      revision: saved.revision,
    };
    this.sync();
  }

  /** Where this authority is, for the core that runs next. */
  protected resumeRecord(): SessionAuthorityResume {
    const snapshot = this.current;
    return {
      authorityInstanceId: this.authorityInstanceId,
      generation: snapshot.generation,
      revision: snapshot.revision,
      sessionId: snapshot.session?.sessionId ?? null,
    };
  }

  // --- Publishing ----------------------------------------------------------------------------------------------

  protected publishSignedIn(projection: SessionProjection): SignedInSessionSnapshot {
    if (
      !this.productOpen() ||
      (this.current.phase === "signed_in" &&
        this.current.session.sessionId !== projection.session_id)
    ) {
      this.revokeGate();
      this.gateOpen = true;
      this.gateSeq += 1;
    }
    const guest = projection.user.kind === "guest";
    const next = this.publish({
      phase: "signed_in",
      principal: {
        ...(projection.user.name ? { displayName: projection.user.name } : {}),
        email: projection.user.email,
        ...(guest ? { kind: "guest" as const } : {}),
        userId: projection.user.id,
      },
      session: {
        audience: this.audience(),
        expiresAtEpochSeconds: projection.expires_at,
        sessionId: projection.session_id,
      },
    });
    if (next.phase !== "signed_in") throw new Error("Expected a signed-in snapshot.");
    this.onSignedIn(guest);
    return next;
  }

  protected publishSignedOut(
    reason: SignedOutSessionSnapshot["reason"]
  ): SignedOutSessionSnapshot {
    this.revokeGate();
    const next = this.publish({
      phase: "signed_out",
      principal: null,
      reason,
      session: null,
    });
    if (next.phase !== "signed_out") throw new Error("Expected a signed-out snapshot.");
    return next;
  }

  protected publishTransient(
    phase: "authenticating" | "invalidating" | "signing_out"
  ): void {
    if (phase !== "authenticating") this.revokeGate();
    this.publish({ phase, principal: null, session: null });
  }

  protected publishIndeterminate(code: ProblemCode, operation: ProblemOperation): void {
    this.revokeGate();
    this.publish({
      phase: "indeterminate",
      principal: null,
      problem: createSessionProblem(code, operation),
      session: null,
    });
  }

  /** The same phase again with the cleanup it has now (a new revision only when it changed). */
  protected publishCleanup(cleanup: SessionCleanup): void {
    const before = this.cleanup;
    this.cleanup = cleanup;
    if (
      before.revocation === cleanup.revocation &&
      (before.revocation !== "pending" ||
        (cleanup.revocation === "pending" &&
          before.pendingCount === cleanup.pendingCount))
    )
      return;
    const {
      authority: _a,
      cleanup: _c,
      contractVersion: _v,
      generation: _g,
      revision: _r,
      ...body
    } = this.current;
    this.publish(body as SnapshotBody, { keepBackground: true });
  }

  protected publish(
    body: SnapshotBody,
    options: { keepBackground?: boolean } = {}
  ): SessionLifecycleSnapshot {
    const current = this.current;
    const currentLease = sessionProductLease(current);
    const nextHasLease = body.phase === "signed_in";
    const leaseChanges =
      Boolean(currentLease) !== nextHasLease ||
      (currentLease !== undefined &&
        body.phase === "signed_in" &&
        currentLease.sessionId !== body.session.sessionId);
    // The first change after taking over from a core that had a lease (resumed one generation before it): the same
    // session again is that lease's generation; another session, or none, is past it.
    const resumed = this.#resumedSessionId;
    this.#resumedSessionId = undefined;
    const step =
      typeof resumed === "string"
        ? body.phase === "signed_in" && body.session.sessionId !== resumed
          ? 2
          : 1
        : leaseChanges
          ? 1
          : 0;
    const merged = mergeSessionSnapshot(current, {
      authority: current.authority,
      cleanup: this.cleanup,
      contractVersion: 1,
      generation: current.generation + step,
      revision: current.revision + 1,
      ...body,
    });
    if (!merged.accepted)
      throw new Error(`Rejected local session transition: ${merged.reason}`);
    if (!options.keepBackground) this.cancelBackground();
    this.current = merged.snapshot;
    this.sync();
    this.onPublished();
    return this.current;
  }

  /** Closes the product gate: the lease is refused from now on. */
  protected revoke(): void {
    this.revokeGate();
    this.sync();
  }

  protected revokeGate(): void {
    this.gateOpen = false;
    this.onGateClosed();
  }

  protected productOpen(): boolean {
    const snapshot = this.current;
    return (
      this.gateOpen &&
      snapshot.phase === "signed_in" &&
      this.credentialHeld(snapshot.session.sessionId)
    );
  }

  /** The lease's key now (one per opening of the gate), or null while none is given. */
  protected gateKey(): string | null {
    return this.productOpen() ? String(this.gateSeq) : null;
  }

  /** What `Session` (the account, the lease, the `session` topic) is told after each change. */
  protected sync(): void {
    this.#watchRecovery();
    const shown = this.recoveryState();
    if (shown !== this.#recoveryShown) {
      this.#recoveryShown = shown;
      for (const listener of Array.from(this.#recoveryListeners)) listener();
    }
    const attempt = this.attempt;
    const now = this.now();
    const seconds = (at: number | undefined) =>
      at === undefined ? 0 : Math.max(0, Math.ceil((at - now) / 1_000));
    if (this.#cooldown && this.#cooldown.until <= now) this.#cooldown = undefined;
    for (const challengeId of Array.from(this.#checked.keys()))
      if (challengeId !== attempt?.challengeId) this.#checked.delete(challengeId);
    const retrySameCode = attempt?.challengeId
      ? this.#checked.get(attempt.challengeId)?.retrySameCode === true
      : false;
    const resendWait = attempt?.email
      ? this.#emailWait(attempt.email.trim().toLowerCase(), now)
      : 0;
    const view: SessionAttempt | null = attempt
      ? {
          ref: attempt.attempt,
          method: attempt.kind,
          ...(attempt.challengeId
            ? {
                challenge: {
                  challengeId: attempt.challengeId,
                  purpose:
                    attempt.kind === "google"
                      ? "google_link"
                      : attempt.kind === "apple"
                        ? "apple_link"
                        : "email_login",
                  ...(attempt.email ? { email: attempt.email } : {}),
                  ...(attempt.expiresAt !== undefined && attempt.expiresAt <= now
                    ? { expired: true }
                    : {}),
                  ...(retrySameCode ? { retrySameCode: true } : {}),
                  // Another code waits for the code's own delay and for the address's retry-after, whichever is longer.
                  ...(resendWait > 0
                    ? { resendInSeconds: Math.ceil(resendWait / 1_000) }
                    : {}),
                },
              }
            : {}),
        }
      : null;
    // The address of a code that still works is not waited on: a request for it goes back to that code.
    const cooldown: SessionEmailCooldown | undefined =
      this.#cooldown && !this.#resumableEmail(this.#cooldown.email, now)
        ? { email: this.#cooldown.email, seconds: seconds(this.#cooldown.until) }
        : undefined;
    this.session.applyLifecycle(this.current, this.gateKey(), {
      attempt: view,
      emailCooldown: cooldown ?? null,
      guestImports: this.guestImports,
    });
    this.#tick(attempt?.expiresAt, [attempt?.resendAt, this.#cooldown?.until], now);
  }

  /** Publishes again when a countdown shown moves to its next second, or when the code expires. */
  #tick(
    expiresAt: number | undefined,
    countdowns: readonly (number | undefined)[],
    now: number
  ): void {
    if (this.#countdown !== null) this.runner.interrupt(this.#countdown);
    this.#countdown = null;
    if (this.closed) return;
    const ahead = (at: number | undefined): at is number =>
      at !== undefined && at > now;
    const next = Math.min(
      ...(ahead(expiresAt) ? [expiresAt - now] : []),
      ...countdowns.filter(ahead).map((at) => ((at - now - 1) % 1_000) + 1)
    );
    if (!Number.isFinite(next)) return;
    this.#countdown = this.runner.fork(
      Effect.sleep(next).pipe(
        Effect.andThen(
          Effect.sync(() => {
            this.#countdown = null;
            this.sync();
          })
        )
      )
    );
  }

  // --- Re-probes and peer reconciles ---------------------------------------------------------------------------

  protected scheduleBackgroundReconcile(): void {
    if (this.#background !== null) return;
    const delay = BACKGROUND_RECONCILE_MS[this.#backgroundAttempt];
    if (delay === undefined) return;
    this.#backgroundAttempt += 1;
    this.#background = this.runner.fork(
      Effect.sleep(delay).pipe(
        Effect.andThen(
          Effect.sync(() => {
            this.#background = null;
            const current = this.current;
            if (this.closed || current.phase !== "signed_in") return;
            this.peerReconcile(sessionExpectation(current));
          })
        )
      )
    );
  }

  protected cancelBackground(): void {
    if (this.#background !== null) this.runner.interrupt(this.#background);
    this.#background = null;
    this.#backgroundAttempt = 0;
  }

  /**
   * A peer reconcile (a product 409, another context's hint, a background re-probe), unless one for the same
   * expectation is queued or running: one core carries every window's requests, and each new reconcile would
   * supersede the one under way (its epoch), so a burst of 409s could put the rebind off without end.
   */
  protected peerReconcile(expected: SessionLifecycleExpectation | undefined): void {
    const key = JSON.stringify(expected ?? null);
    if (this.#peerKey === key || this.closed) return;
    this.#peerKey = key;
    this.fork(
      this.reconcile({
        ...(expected ? { expected } : {}),
        reason: "peer_mutation",
      }).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#peerKey === key) this.#peerKey = null;
          })
        )
      )
    );
  }

  // --- Fencing -------------------------------------------------------------------------------------------------

  protected localExpectationMatches(expected: SessionLifecycleExpectation): boolean {
    const current = this.current;
    if (
      expected.authorityInstanceId !== this.authorityInstanceId ||
      expected.generation !== current.generation
    )
      return false;
    if (current.phase === "signed_out") return expected.expectedSessionId === null;
    if (current.phase === "signed_in")
      return (
        expected.expectedSessionId === current.session.sessionId &&
        "expectedAudience" in expected &&
        expected.expectedAudience === current.session.audience
      );
    if (current.phase === "indeterminate") {
      const known = this.indeterminateSessionId();
      if (known === undefined) return false;
      if (known === null) return expected.expectedSessionId === null;
      return (
        expected.expectedSessionId === known &&
        "expectedAudience" in expected &&
        expected.expectedAudience === this.audience()
      );
    }
    return false;
  }

  protected canStartAuthentication(expected: SessionAbsenceExpectation): boolean {
    const current = this.current;
    return (
      (current.phase === "signed_out" || current.phase === "authenticating") &&
      expected.authorityInstanceId === this.authorityInstanceId &&
      expected.generation === current.generation &&
      expected.expectedSessionId === null
    );
  }

  protected newAttempt(expected: SessionAbsenceExpectation): SessionAuthAttemptRef {
    return { attemptId: this.randomId(), expected };
  }

  protected isCurrentAttempt(
    attempt: SessionAuthAttemptRef,
    operationEpoch?: number
  ): boolean {
    const current = this.attempt;
    return (
      current !== undefined &&
      current.attempt.attemptId === attempt.attemptId &&
      current.attempt.expected.authorityInstanceId ===
        attempt.expected.authorityInstanceId &&
      current.attempt.expected.generation === attempt.expected.generation &&
      (operationEpoch === undefined || current.operationEpoch === operationEpoch)
    );
  }

  protected nextEpoch(): number {
    this.epoch += 1;
    return this.epoch;
  }

  protected isCurrentEpoch(epoch: number): boolean {
    return epoch === this.epoch;
  }

  // --- Failures ------------------------------------------------------------------------------------------------

  protected failure<Operation extends SessionOperationName>(
    operation: Operation,
    code: SessionOperationErrorCodeFor<Operation>
  ): SessionOperationResult<never, Operation> {
    return {
      error: createSessionOperationError(operation, code, this.current),
      ok: false,
    };
  }

  /** A failure for `operation` with `code`, or `unknown` when the contract has no such failure for it. */
  protected failureOrUnknown<Operation extends SessionOperationName>(
    operation: Operation,
    code: string,
    retryAfterMs?: number
  ): SessionOperationResult<never, Operation> {
    return {
      error: createSessionOperationErrorOrUnknown(
        operation,
        code as never,
        this.current,
        retryAfterMs
      ),
      ok: false,
    };
  }

  /** Runs what no caller waits for (the startup probe, a product refusal, a hint); a defect still settles the snapshot. */
  protected fork(effect: Effect.Effect<unknown>): void {
    if (!this.closed)
      this.runner.fork(this.guard(effect, "reconcile", () => undefined));
  }

  /**
   * `effect`, a defect in it answered by `fallback` after the snapshot is moved out of a phase nothing else would end
   * (`initializing`, `signing_out`, `invalidating`).
   */
  guard<A>(
    effect: Effect.Effect<A>,
    operation: "authenticate" | "reconcile" | "sign_out",
    fallback: () => A
  ): Effect.Effect<A> {
    return effect.pipe(
      Effect.catchDefect((defect) =>
        Effect.sync(() => {
          console.error("comma core: the session lifecycle failed", defect);
          this.unstick(operation);
          return fallback();
        })
      )
    );
  }

  /** A failure `unknown` for `operation`, against the snapshot now. */
  unknownFailure<Operation extends SessionOperationName>(
    operation: Operation
  ): SessionOperationResult<never, Operation> {
    return this.failureOrUnknown(operation, "unknown");
  }

  /** Out of a phase only the operation that failed would have ended: undecided, the lease closed. */
  protected unstick(
    operation: "authenticate" | "reconcile" | "sign_out" | "invalidate"
  ): void {
    const phase = this.current.phase;
    if (
      this.closed ||
      (phase !== "initializing" && phase !== "signing_out" && phase !== "invalidating")
    )
      return;
    try {
      this.publishIndeterminate(
        "session_probe_unavailable",
        phase === "initializing"
          ? "initialize"
          : phase === "invalidating"
            ? "invalidate"
            : operation
      );
    } catch (error) {
      console.error("comma core: the session snapshot could not be settled", error);
    }
  }

  /** A random id (the host's random bytes), as a UUID's text. */
  protected randomId(): string {
    const bytes = new Uint8Array(16);
    this.host.randomBytes(bytes);
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
}
