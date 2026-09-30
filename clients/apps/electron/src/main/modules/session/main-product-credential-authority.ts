import {
  createSessionProblem,
  sameSessionProductLease,
  sessionAdmissionFailureSchema,
  sessionCleanupSchema,
  sessionLifecycleSnapshotSchema,
  sessionPresenceExpectationSchema,
  sessionProblemSchema,
  sessionRecoveryRef,
  type SessionAdmissionFailure,
  type SessionCleanup,
  type SessionLifecycleSnapshot,
  type SessionPresenceExpectation,
  type SessionProblem,
} from "@comma/session-contract";
import {
  canonicalizeSessionAudience,
  secureSessionActiveCredentialSchema,
  type SecureSessionActiveCredential,
} from "./credential";

export type MainProductCredentialLease = Readonly<{
  audience: string;
  authorityInstanceId: string;
  generation: number;
  sessionId: string;
  signal: AbortSignal;
  token: string;
}>;

export interface MainProductCredentialAuthorityOptions {
  authorityInstanceId: string;
  cleanup?: SessionCleanup | undefined;
  onSnapshotChanged?: ((snapshot: SessionLifecycleSnapshot) => void) | undefined;
  persistedCredential?: SecureSessionActiveCredential | undefined;
  trustedAudience: string;
}

/**
 * Main-only bearer gate. It owns no transport, reconciliation, revocation, or
 * durable cleanup behavior; callers settle those operations outside this
 * class, using its exact lease and synchronous close transitions as fences.
 */
export class MainProductCredentialAuthority {
  readonly #authorityInstanceId: string;
  #closed = false;
  #controller: AbortController | undefined;
  #credential: SecureSessionActiveCredential | undefined;
  #gateOpen = false;
  readonly #onSnapshotChanged:
    | ((snapshot: SessionLifecycleSnapshot) => void)
    | undefined;
  #snapshot: SessionLifecycleSnapshot;
  readonly #trustedAudience: string;

  constructor(options: MainProductCredentialAuthorityOptions) {
    this.#authorityInstanceId = options.authorityInstanceId;
    this.#trustedAudience = canonicalizeSessionAudience(options.trustedAudience);
    this.#onSnapshotChanged = options.onSnapshotChanged;

    const cleanup = sessionCleanupSchema.parse(
      options.cleanup ?? { revocation: "idle" }
    );
    const persistedCredential = options.persistedCredential
      ? secureSessionActiveCredentialSchema.parse(options.persistedCredential)
      : undefined;
    const persistedCredentialAudience = persistedCredential?.audience;

    if (
      persistedCredentialAudience &&
      persistedCredentialAudience !== this.#trustedAudience
    ) {
      this.#snapshot = this.#indeterminateSnapshot(
        createSessionProblem("protocol_mismatch", "initialize"),
        cleanup,
        0,
        0
      );
      return;
    }

    this.#credential = persistedCredential;
    this.#snapshot = persistedCredentialAudience
      ? this.#transientSnapshot("initializing", cleanup, 0, 0)
      : this.#signedOutSnapshot("no_session", cleanup, 0, 0);
  }

  getSnapshot(): SessionLifecycleSnapshot {
    return sessionLifecycleSnapshotSchema.parse(this.#snapshot);
  }

  acquireProductCredential(
    expectedValue: SessionPresenceExpectation
  ): MainProductCredentialLease | null {
    if (this.#closed || !this.#gateOpen || !this.#credential || !this.#controller) {
      return null;
    }

    const expected = sessionPresenceExpectationSchema.safeParse(expectedValue);
    if (!expected.success) return null;

    const current = this.#currentLeaseIdentity();
    if (!current || !expectationMatchesLease(expected.data, current)) {
      return null;
    }

    return Object.freeze({
      ...current,
      signal: this.#controller.signal,
      token: this.#credential.token,
    });
  }

  isCurrentProductCredential(lease: MainProductCredentialLease): boolean {
    if (
      this.#closed ||
      !this.#gateOpen ||
      !this.#credential ||
      !this.#controller ||
      lease.signal.aborted ||
      lease.signal !== this.#controller.signal ||
      lease.token !== this.#credential.token
    ) {
      return false;
    }

    const current = this.#currentLeaseIdentity();
    return Boolean(
      current &&
      sameSessionProductLease(current, {
        audience: lease.audience,
        authorityInstanceId: lease.authorityInstanceId,
        generation: lease.generation,
        sessionId: lease.sessionId,
      })
    );
  }

  admissionFailure(): SessionAdmissionFailure {
    return sessionAdmissionFailureSchema.parse({
      code: "session_product_lease_unavailable",
      recovery: sessionRecoveryRef(this.#snapshot),
    });
  }

  /**
   * Opens a new verified product generation. A persisted credential must reach
   * this method only after its bounded current-session reconciliation succeeds.
   */
  acceptVerifiedCredential(
    credentialValue: SecureSessionActiveCredential
  ): SessionLifecycleSnapshot {
    this.#assertOpen();
    const credential = secureSessionActiveCredentialSchema.parse(credentialValue);

    const hadLease = this.#snapshot.phase === "signed_in";
    this.closeProductCredentialGate();
    if (credential.audience !== this.#trustedAudience) {
      this.#credential = undefined;
      return this.#publish(
        this.#indeterminateSnapshot(
          createSessionProblem("protocol_mismatch", "reconcile"),
          this.#snapshot.cleanup,
          hadLease
            ? incrementVersion(this.#snapshot.generation, "generation")
            : this.#snapshot.generation,
          incrementVersion(this.#snapshot.revision, "revision")
        )
      );
    }

    const generation = incrementVersion(this.#snapshot.generation, "generation");
    const revision = incrementVersion(this.#snapshot.revision, "revision");
    this.#credential = credential;
    this.#controller = new AbortController();
    this.#gateOpen = true;
    return this.#publish(
      sessionLifecycleSnapshotSchema.parse({
        authority: this.#authority(),
        cleanup: this.#snapshot.cleanup,
        contractVersion: 1,
        generation,
        phase: "signed_in",
        principal: {
          email: credential.email,
          userId: credential.userId,
        },
        revision,
        session: {
          audience: credential.audience,
          expiresAtEpochSeconds: credential.expiresAtEpochSeconds,
          sessionId: credential.sessionId,
        },
      })
    );
  }

  updateCleanup(cleanupValue: SessionCleanup): SessionLifecycleSnapshot {
    this.#assertOpen();
    const cleanup = sessionCleanupSchema.parse(cleanupValue);
    if (sessionCleanupEqual(cleanup, this.#snapshot.cleanup)) {
      return this.getSnapshot();
    }

    return this.#publish(
      sessionLifecycleSnapshotSchema.parse({
        ...this.#snapshot,
        cleanup,
        revision: incrementVersion(this.#snapshot.revision, "revision"),
      })
    );
  }

  beginAuthentication(): SessionLifecycleSnapshot | null {
    this.#assertOpen();
    if (
      this.#snapshot.phase !== "signed_out" &&
      this.#snapshot.phase !== "authenticating"
    ) {
      return null;
    }

    this.closeProductCredentialGate();
    return this.#publish(
      this.#transientSnapshot(
        "authenticating",
        this.#snapshot.cleanup,
        this.#snapshot.generation,
        incrementVersion(this.#snapshot.revision, "revision")
      )
    );
  }

  beginSignOut(): SessionLifecycleSnapshot {
    this.#assertOpen();
    const hadLease = this.#snapshot.phase === "signed_in";
    this.closeProductCredentialGate();
    return this.#publish(
      this.#transientSnapshot(
        "signing_out",
        this.#snapshot.cleanup,
        hadLease
          ? incrementVersion(this.#snapshot.generation, "generation")
          : this.#snapshot.generation,
        incrementVersion(this.#snapshot.revision, "revision")
      )
    );
  }

  beginInvalidation(
    expectedValue?: SessionPresenceExpectation
  ): SessionLifecycleSnapshot | null {
    this.#assertOpen();
    if (this.#snapshot.phase !== "signed_in") return null;

    if (expectedValue !== undefined) {
      const expected = sessionPresenceExpectationSchema.safeParse(expectedValue);
      const current = this.#currentLeaseIdentity();
      if (
        !expected.success ||
        !current ||
        !expectationMatchesLease(expected.data, current)
      ) {
        return null;
      }
    }

    this.closeProductCredentialGate();
    return this.#publish(
      this.#transientSnapshot(
        "invalidating",
        this.#snapshot.cleanup,
        incrementVersion(this.#snapshot.generation, "generation"),
        incrementVersion(this.#snapshot.revision, "revision")
      )
    );
  }

  settleSignedOut(
    reason: "expired" | "no_session" | "unauthorized" | "user_signed_out"
  ): SessionLifecycleSnapshot {
    this.#assertOpen();
    this.closeProductCredentialGate();
    this.#credential = undefined;
    return this.#publish(
      this.#signedOutSnapshot(
        reason,
        this.#snapshot.cleanup,
        this.#snapshot.generation,
        incrementVersion(this.#snapshot.revision, "revision")
      )
    );
  }

  markIndeterminate(problemValue: SessionProblem): SessionLifecycleSnapshot {
    this.#assertOpen();
    const problem = sessionProblemSchema.parse(problemValue);
    const hadLease = this.#snapshot.phase === "signed_in";
    this.closeProductCredentialGate();
    this.#credential = undefined;
    return this.#publish(
      this.#indeterminateSnapshot(
        problem,
        this.#snapshot.cleanup,
        hadLease
          ? incrementVersion(this.#snapshot.generation, "generation")
          : this.#snapshot.generation,
        incrementVersion(this.#snapshot.revision, "revision")
      )
    );
  }

  closeProductCredentialGate(): void {
    this.#gateOpen = false;
    this.#controller?.abort();
    this.#controller = undefined;
  }

  close(): void {
    this.closeProductCredentialGate();
    this.#closed = true;
    this.#credential = undefined;
  }

  #currentLeaseIdentity() {
    if (this.#snapshot.phase !== "signed_in") return undefined;
    return {
      audience: this.#snapshot.session.audience,
      authorityInstanceId: this.#snapshot.authority.authorityInstanceId,
      generation: this.#snapshot.generation,
      sessionId: this.#snapshot.session.sessionId,
    };
  }

  #publish(snapshot: SessionLifecycleSnapshot): SessionLifecycleSnapshot {
    this.#snapshot = snapshot;
    const published = this.getSnapshot();
    this.#onSnapshotChanged?.(published);
    return published;
  }

  #authority() {
    return {
      authorityInstanceId: this.#authorityInstanceId,
      kind: "electron_main" as const,
    };
  }

  #transientSnapshot(
    phase: "authenticating" | "initializing" | "invalidating" | "signing_out",
    cleanup: SessionCleanup,
    generation: number,
    revision: number
  ): SessionLifecycleSnapshot {
    return sessionLifecycleSnapshotSchema.parse({
      authority: this.#authority(),
      cleanup,
      contractVersion: 1,
      generation,
      phase,
      principal: null,
      revision,
      session: null,
    });
  }

  #signedOutSnapshot(
    reason: "expired" | "no_session" | "unauthorized" | "user_signed_out",
    cleanup: SessionCleanup,
    generation: number,
    revision: number
  ): SessionLifecycleSnapshot {
    return sessionLifecycleSnapshotSchema.parse({
      authority: this.#authority(),
      cleanup,
      contractVersion: 1,
      generation,
      phase: "signed_out",
      principal: null,
      reason,
      revision,
      session: null,
    });
  }

  #indeterminateSnapshot(
    problem: SessionProblem,
    cleanup: SessionCleanup,
    generation: number,
    revision: number
  ): SessionLifecycleSnapshot {
    return sessionLifecycleSnapshotSchema.parse({
      authority: this.#authority(),
      cleanup,
      contractVersion: 1,
      generation,
      phase: "indeterminate",
      principal: null,
      problem,
      revision,
      session: null,
    });
  }

  #assertOpen(): void {
    if (this.#closed) {
      throw new Error("MainProductCredentialAuthority is closed.");
    }
  }
}

function incrementVersion(value: number, name: "generation" | "revision") {
  if (!Number.isSafeInteger(value) || value >= Number.MAX_SAFE_INTEGER) {
    throw new Error(`Session ${name} is exhausted; replace the authority.`);
  }
  return value + 1;
}

function sessionCleanupEqual(left: SessionCleanup, right: SessionCleanup) {
  if (left.revocation !== right.revocation) return false;
  return (
    left.revocation !== "pending" ||
    (right.revocation === "pending" && left.pendingCount === right.pendingCount)
  );
}

function expectationMatchesLease(
  expected: SessionPresenceExpectation,
  lease: {
    audience: string;
    authorityInstanceId: string;
    generation: number;
    sessionId: string;
  }
) {
  return (
    expected.authorityInstanceId === lease.authorityInstanceId &&
    expected.generation === lease.generation &&
    expected.expectedSessionId === lease.sessionId &&
    expected.expectedAudience === lease.audience
  );
}
