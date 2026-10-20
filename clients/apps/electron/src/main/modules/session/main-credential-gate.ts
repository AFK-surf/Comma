import {
  sameSessionProductLease,
  sessionAdmissionFailureSchema,
  sessionLifecycleSnapshotSchema,
  sessionPresenceExpectationSchema,
  sessionProductLease,
  sessionRecoveryRef,
  type SessionAdmissionFailure,
  type SessionLifecycleSnapshot,
  type SessionPresenceExpectation,
  type SessionProductLease,
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

/** Where the gate is, for a core that starts (again): the authority it continues, and the lease still open. */
export interface MainCredentialGateResume {
  authorityInstanceId: string;
  generation: number;
  revision: number;
  sessionId: string | null;
}

export interface MainCredentialGateOptions {
  authorityInstanceId: string;
  onSnapshotChanged?: ((snapshot: SessionLifecycleSnapshot) => void) | undefined;
  trustedAudience: string;
}

/**
 * Main's synchronous bearer gate. The client core runs the session lifecycle and is its authority; Main holds the
 * credential and follows what the core publishes: each snapshot the core publishes reaches the gate before any
 * window or request acts on it, and the gate opens a lease only for the active credential in Main's store that names
 * the lease's session, at the lease's generation. Main's consumers (the `/v1` proxy, native session admission, the
 * connector runtime, the compute-node install, the activity reporter) take the bearer through it synchronously, and
 * a request made for any other generation is refused. A 401 Main sees closes the gate at once (`revoke`): it is not
 * opened again at that generation, so a core that restarts after it opens a new one.
 *
 * While no core runs (it restarts, or this build has none), the gate keeps what the core last confirmed, read only:
 * it serves that lease and nothing else, and nothing here opens another.
 */
export class MainCredentialGate {
  readonly #authorityInstanceId: string;
  readonly #trustedAudience: string;
  readonly #onSnapshotChanged:
    | ((snapshot: SessionLifecycleSnapshot) => void)
    | undefined;
  #closed = false;
  #controller: AbortController | undefined;
  #credential: SecureSessionActiveCredential | undefined;
  #lease: SessionProductLease | undefined;
  /** The highest generation whose lease a 401 closed: no lease at or below it opens again. */
  #revokedGeneration = -1;
  #snapshot: SessionLifecycleSnapshot;

  constructor(options: MainCredentialGateOptions) {
    this.#authorityInstanceId = options.authorityInstanceId;
    this.#trustedAudience = canonicalizeSessionAudience(options.trustedAudience);
    this.#onSnapshotChanged = options.onSnapshotChanged;
    // Nothing is known until the core says: the gate starts shut.
    this.#snapshot = sessionLifecycleSnapshotSchema.parse({
      authority: {
        authorityInstanceId: this.#authorityInstanceId,
        kind: "electron_main",
      },
      cleanup: { revocation: "unknown" },
      contractVersion: 1,
      generation: 0,
      phase: "initializing",
      principal: null,
      revision: 0,
      session: null,
    });
  }

  getSnapshot(): SessionLifecycleSnapshot {
    return this.#snapshot;
  }

  /** What a core that starts continues: this authority, where it is, and the session whose lease is open (or none). */
  resume(): MainCredentialGateResume {
    return {
      authorityInstanceId: this.#authorityInstanceId,
      generation: this.#snapshot.generation,
      revision: this.#snapshot.revision,
      sessionId: this.#isOpen() ? (this.#lease?.sessionId ?? null) : null,
    };
  }

  /**
   * The snapshot the core published, the lease it gives with it (none: shut), and Main's active credential. Applied in
   * the order told. A snapshot of another authority, an older one, or one whose generation went back is refused (the
   * gate shuts); a lease opens only for `credential` when it names the lease's session and audience, at a generation
   * no 401 closed. True when the snapshot was taken.
   */
  follow(
    snapshotValue: unknown,
    leaseValue: SessionProductLease | null,
    credentialValue: SecureSessionActiveCredential | undefined
  ): boolean {
    if (this.#closed) return false;
    const parsed = sessionLifecycleSnapshotSchema.safeParse(snapshotValue);
    if (
      !parsed.success ||
      parsed.data.authority.authorityInstanceId !== this.#authorityInstanceId ||
      parsed.data.revision <= this.#snapshot.revision ||
      parsed.data.generation < this.#snapshot.generation
    ) {
      this.closeProductCredentialGate();
      return false;
    }
    const snapshot = parsed.data;
    const lease = leaseValue ? sessionProductLease(snapshot) : undefined;
    const credential = credentialValue
      ? secureSessionActiveCredentialSchema.safeParse(credentialValue)
      : undefined;
    const opens =
      lease !== undefined &&
      leaseValue !== null &&
      sameSessionProductLease(lease, leaseValue) &&
      lease.audience === this.#trustedAudience &&
      lease.generation > this.#revokedGeneration &&
      credential?.success === true &&
      credential.data.audience === lease.audience &&
      credential.data.sessionId === lease.sessionId;
    if (!opens) this.closeProductCredentialGate();
    else if (
      !this.#isOpen() ||
      !this.#lease ||
      !sameSessionProductLease(this.#lease, lease) ||
      this.#credential?.token !== credential.data.token
    ) {
      this.closeProductCredentialGate();
      this.#credential = credential.data;
      this.#lease = lease;
      this.#controller = new AbortController();
    }
    this.#snapshot = snapshot;
    this.#onSnapshotChanged?.(snapshot);
    return true;
  }

  /** A 401 Main saw for `lease`: the gate shuts now, fail-closed, and that generation never opens again. */
  revoke(lease: MainProductCredentialLease): boolean {
    if (!this.isCurrentProductCredential(lease)) return false;
    this.#revokedGeneration = Math.max(this.#revokedGeneration, lease.generation);
    this.closeProductCredentialGate();
    return true;
  }

  acquireProductCredential(
    expectedValue: SessionPresenceExpectation
  ): MainProductCredentialLease | null {
    if (!this.#isOpen()) return null;
    const expected = sessionPresenceExpectationSchema.safeParse(expectedValue);
    const lease = this.#lease!;
    if (
      !expected.success ||
      expected.data.authorityInstanceId !== lease.authorityInstanceId ||
      expected.data.generation !== lease.generation ||
      expected.data.expectedSessionId !== lease.sessionId ||
      expected.data.expectedAudience !== lease.audience
    )
      return null;
    return Object.freeze({
      ...lease,
      signal: this.#controller!.signal,
      token: this.#credential!.token,
    });
  }

  isCurrentProductCredential(lease: MainProductCredentialLease): boolean {
    return (
      this.#isOpen() &&
      !lease.signal.aborted &&
      lease.signal === this.#controller!.signal &&
      lease.token === this.#credential!.token &&
      sameSessionProductLease(this.#lease!, {
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

  closeProductCredentialGate(): void {
    this.#controller?.abort();
    this.#controller = undefined;
    this.#credential = undefined;
    this.#lease = undefined;
  }

  close(): void {
    this.closeProductCredentialGate();
    this.#closed = true;
  }

  #isOpen(): boolean {
    return (
      !this.#closed &&
      this.#controller !== undefined &&
      this.#credential !== undefined &&
      this.#lease !== undefined
    );
  }
}
