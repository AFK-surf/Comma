import { randomUUID } from "node:crypto";
import {
  type SessionLifecycleSnapshot,
  type SessionPresenceExpectation,
  type SessionProductLease,
} from "@comma/session-contract";
import type {
  BearerVault,
  BearerVaultChange,
  GoogleGrant,
} from "@comma/core/utility-protocol";
import { z } from "zod";
import type { DesktopGoogleAuthProvider } from "../../google-desktop-auth";
import type {
  SecureSessionStore,
  SecureSessionVaultActive,
  SecureSessionVaultSnapshot,
} from "../../secure-store";
import {
  canonicalizeSessionAudience,
  secureSessionActiveCredentialSchema,
  type SecureSessionActiveCredential,
} from "./credential";
import {
  MainCredentialGate,
  type MainCredentialGateResume,
  type MainProductCredentialLease,
} from "./main-credential-gate";

/** An auth request the core asks Main to make: the credential it names is attached here. */
export interface MainAuthRequest {
  method: "GET" | "POST";
  path: string;
  headers: [string, string][];
  body: Uint8Array | null;
  credential?: string | undefined;
}

export interface MainAuthResponse {
  status: number;
  headers: [string, string][];
  body: Uint8Array;
}

export interface MainSessionHostOptions {
  authorityInstanceId?: string | undefined;
  fetch?: typeof fetch | undefined;
  googleAuth?: DesktopGoogleAuthProvider | undefined;
  onSnapshotChanged?:
    | ((snapshot: SessionLifecycleSnapshot) => Promise<void> | void)
    | undefined;
  store: SecureSessionStore;
  trustedAudience: string;
}

/** The identity an answer that issued a bearer names (the bearer itself is taken out before the core sees it). */
const issuedIdentitySchema = z.object({
  expires_at: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  session_id: z.string().min(1).max(256),
  user: z.object({
    email: z.string().min(1).max(320),
    id: z.string().min(1).max(256),
  }),
});

/** The headers an auth request keeps from the core; Main adds the transport and the credential. */
const authRequestHeaders = new Set(["accept", "content-type"]);
/** The headers of an answer the core reads. */
const authResponseHeaders = new Set(["content-type", "retry-after"]);

type Issued = {
  token: string;
  /** The whole credential, when the answer named whose it is (it can then become the active one). */
  credential?: SecureSessionActiveCredential | undefined;
  sessionId?: string | undefined;
  /** The core's request that carried it: an answer the core never took is quarantined (`dropped`). */
  requestId?: number | undefined;
};

/**
 * Main's part of the Electron session. The client core runs the session lifecycle (its state machine,
 * packages/core/src/session/electron-lifecycle.ts) and is its authority; Main keeps what the core must never see:
 *
 * - the bearer, in `SecureSessionStore` (the OS keychain's encryption). The core names credentials by opaque
 *   references (`vault`, `change`), and asks Main to change the store by reference;
 * - the auth endpoints' transport (`authFetch`): Main attaches the credential a request names, and takes any bearer
 *   out of an answer (a sign-in's, a reflected one), keeping it here and answering a reference instead;
 * - the gate (`MainCredentialGate`), which follows each snapshot the core publishes (`gate`) and gives Main's
 *   consumers the bearer synchronously, for exactly the current lease;
 * - the Google sign-in window (`google`).
 *
 * A bearer the core was told about by reference but has not settled (committed, queued, released) stays in Main's
 * custody: when the core goes, or Main closes, Main queues it for revocation, or revokes it at the server, and
 * refuses to close while one is left.
 */
export class MainSessionHost {
  readonly #gate: MainCredentialGate;
  readonly #fetch: typeof fetch;
  readonly #googleAuth: DesktopGoogleAuthProvider | undefined;
  readonly #store: SecureSessionStore;
  readonly #trustedAudience: string;
  readonly #issued = new Map<string, Issued>();
  /** Issued bearers the core committed: one it later quarantines (a sign-in it overtook) leaves the store. */
  readonly #committed = new Set<string>();
  readonly #refs = new Map<string, string>();
  readonly #tokens = new Map<string, string>();
  readonly #grants = new Map<string, (success: boolean) => void>();
  readonly #rejectedListeners = new Set<(lease: SessionProductLease) => void>();
  readonly #settledWaiters = new Set<() => void>();
  #closed = false;

  constructor(options: MainSessionHostOptions) {
    this.#store = options.store;
    this.#fetch = options.fetch ?? fetch;
    this.#googleAuth = options.googleAuth;
    this.#trustedAudience = canonicalizeSessionAudience(options.trustedAudience);
    this.#gate = new MainCredentialGate({
      authorityInstanceId: options.authorityInstanceId ?? randomUUID(),
      onSnapshotChanged: (snapshot) => {
        if (snapshot.phase !== "initializing") {
          for (const settle of this.#settledWaiters) settle();
          this.#settledWaiters.clear();
        }
        void options.onSnapshotChanged?.(snapshot);
      },
      trustedAudience: this.#trustedAudience,
    });
  }

  get authority(): MainCredentialGate {
    return this.#gate;
  }

  get apiOrigin(): string {
    return this.#trustedAudience;
  }

  state(): SessionLifecycleSnapshot {
    return this.#gate.getSnapshot();
  }

  acquireProductCredential(
    expected: SessionPresenceExpectation
  ): MainProductCredentialLease | null {
    return this.#gate.acquireProductCredential(expected);
  }

  isCurrentProductCredential(lease: MainProductCredentialLease): boolean {
    return this.#gate.isCurrentProductCredential(lease);
  }

  admissionFailure() {
    return this.#gate.admissionFailure();
  }

  /**
   * A 401 to a request Main made with `lease` (its `/v1` proxy, a native consumer): the gate shuts now, whether or not
   * a core runs, and the core is told so it invalidates the session (a core that is away reconciles when it starts).
   */
  async reportUnauthorized(lease: MainProductCredentialLease): Promise<void> {
    if (!this.#gate.revoke(lease)) return;
    const identity: SessionProductLease = {
      audience: lease.audience,
      authorityInstanceId: lease.authorityInstanceId,
      generation: lease.generation,
      sessionId: lease.sessionId,
    };
    for (const listener of this.#rejectedListeners) listener(identity);
  }

  /**
   * Resolves once the core has published what the session is (anything but `initializing`), or after `withinMs`:
   * startup decides its first windows on it, as it did when Main checked the session itself.
   */
  settled(withinMs: number): Promise<void> {
    if (this.state().phase !== "initializing") return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(done, withinMs);
      function done() {
        clearTimeout(timer);
        resolve();
      }
      this.#settledWaiters.add(done);
    });
  }

  /** Told each lease a 401 closed (the core host forwards it to the core). */
  onRejected(listener: (lease: SessionProductLease) => void): () => void {
    this.#rejectedListeners.add(listener);
    return () => this.#rejectedListeners.delete(listener);
  }

  // --- The core's ports --------------------------------------------------------------------------------------------

  /** Where the gate is: what a core that starts continues. */
  resume(): MainCredentialGateResume {
    return this.#gate.resume();
  }

  /** The core's snapshot and lease: the gate moves now, in the order told. */
  gate(snapshot: unknown, lease: SessionProductLease | null): void {
    const vault = this.#store.getVaultSnapshot();
    const active =
      vault.status === "readable" && vault.active
        ? activeCredential(vault.active)
        : undefined;
    this.#gate.follow(snapshot, lease, active);
  }

  /** An auth request for the core: the credential it names attached, a bearer in the answer kept here. */
  async authFetch(
    request: MainAuthRequest,
    options: { requestId?: number; signal?: AbortSignal } = {}
  ): Promise<MainAuthResponse> {
    if (this.#closed) throw new Error("Main's session host is closed.");
    if (!request.path.startsWith("/v1/comma/auth/"))
      throw new Error("Only the auth endpoints are made for the session lifecycle.");
    const url = new URL(request.path, this.#trustedAudience);
    if (url.origin !== this.#trustedAudience)
      throw new Error("The auth request escaped its audience.");
    const headers = new Headers();
    for (const [name, value] of request.headers)
      if (authRequestHeaders.has(name.toLowerCase())) headers.set(name, value);
    headers.set("x-comma-session-transport", "bearer");
    if (request.credential !== undefined) {
      const token = this.#tokenFor(request.credential);
      if (!token) throw new Error("The credential named is not kept.");
      headers.set("authorization", `Bearer ${token}`);
    }
    const response = await this.#fetch(url, {
      ...(request.body ? { body: Buffer.from(request.body) } : {}),
      credentials: "omit",
      headers,
      method: request.method,
      redirect: "manual",
      ...(options.signal ? { signal: options.signal } : {}),
    });
    const body = new Uint8Array(await response.arrayBuffer());
    return {
      body: this.#keepBearer(body, options.requestId),
      headers: [...response.headers].filter(([name]) =>
        authResponseHeaders.has(name.toLowerCase())
      ),
      status: response.status,
    };
  }

  /** The credential store, read again from its file: no bearer in it, each credential by reference. */
  async vault(): Promise<BearerVault> {
    await this.#store.refresh();
    return this.#view(this.#store.getVaultSnapshot());
  }

  /** A change of the credential store the core asks for, by reference. */
  async change(change: BearerVaultChange): Promise<BearerVault | boolean | null> {
    switch (change.kind) {
      case "commit": {
        const issued = this.#issued.get(change.issued);
        if (!issued?.credential) return null;
        const vault = this.#store.getVaultSnapshot();
        const active =
          vault.status === "readable" && vault.active
            ? activeCredential(vault.active)
            : undefined;
        const superseded = change.supersede.flatMap((ref) => {
          const candidate = this.#issued.get(ref)?.credential;
          if (candidate) return [candidate];
          // A superseded sign-in whose commit landed is the active credential now.
          return active && this.#tokenFor(ref) === active.token ? [active] : [];
        });
        await this.#store.setSession(issued.credential, {
          supersededCredentials: superseded,
        });
        this.#issued.delete(change.issued);
        this.#committed.add(change.issued);
        for (const ref of change.supersede) this.#issued.delete(ref);
        return this.#view(this.#store.getVaultSnapshot());
      }
      case "adopt": {
        const token = this.#tokenFor(change.active);
        for (let attempt = 0; attempt < 3; attempt += 1) {
          const vault = this.#store.getVaultSnapshot();
          if (
            vault.status !== "readable" ||
            !vault.active ||
            vault.active.token !== token ||
            vault.active.audience !== this.#trustedAudience
          )
            return null;
          const committed = await this.#store.compareAndSetVault(
            {
              sourceIdentity: vault.sourceIdentity,
              vaultRevision: vault.vaultRevision,
            },
            {
              active: secureSessionActiveCredentialSchema.parse({
                ...change.identity,
                audience: vault.active.audience,
                token: vault.active.token,
              }),
              pendingRevocations: vault.pendingRevocations,
            }
          );
          if (committed) return this.#view(committed);
        }
        return null;
      }
      case "invalidate": {
        const vault = this.#store.getVaultSnapshot();
        const token = this.#tokenFor(change.active);
        if (
          vault.status !== "readable" ||
          !vault.active ||
          vault.active.token !== token
        )
          return null;
        const removed = await this.#store.invalidateSession({
          audience: vault.active.audience,
          sessionId: vault.active.sessionId,
          token: vault.active.token,
        });
        return removed ? this.#view(this.#store.getVaultSnapshot()) : null;
      }
      case "signOut":
        await this.#store.beginSignOut();
        return this.#view(this.#store.getVaultSnapshot());
      case "quarantine":
        return this.#quarantine(change.issued);
      case "release":
        this.#issued.delete(change.issued);
        return true;
      case "revoked": {
        const vault = this.#store.getVaultSnapshot();
        const token = this.#tokenFor(change.pending);
        const pending =
          vault.status === "readable"
            ? vault.pendingRevocations.find((record) => record.token === token)
            : undefined;
        if (!pending) return null;
        await this.#store.completeRevocation(pending);
        return this.#view(this.#store.getVaultSnapshot());
      }
      case "retainAudience": {
        const vault = this.#store.getVaultSnapshot();
        if (vault.status !== "readable") return null;
        // A configured backend change retires only credentials for other origins. Local removal does not claim
        // remote revocation or contact the old origin.
        this.#gate.closeProductCredentialGate();
        const committed = await this.#store.compareAndSetVault(vault, {
          ...(vault.active?.audience === this.#trustedAudience
            ? { active: activeCredential(vault.active) }
            : {}),
          pendingRevocations: vault.pendingRevocations.filter(
            (pending) => pending.audience === this.#trustedAudience
          ),
        });
        return committed ? this.#view(committed) : null;
      }
    }
  }

  /** The Google sign-in window; the grant names it until `googleDone`. */
  async google(
    input: { clientId: string; nonce: string },
    signal?: AbortSignal
  ): Promise<GoogleGrant> {
    if (!this.#googleAuth) throw new Error("Google sign-in is unavailable.");
    const authorization = await this.#googleAuth.authenticate({
      clientId: input.clientId,
      nonce: input.nonce,
      signal: signal ?? new AbortController().signal,
    });
    const grant = randomUUID();
    this.#grants.set(grant, (success) => authorization.complete(success));
    return {
      authorizationCode: authorization.authorizationCode,
      codeVerifier: authorization.codeVerifier,
      grant,
      redirectUri: authorization.redirectUri,
    };
  }

  googleDone(grant: string, ok: boolean): void {
    const complete = this.#grants.get(grant);
    this.#grants.delete(grant);
    complete?.(ok);
  }

  /** The core never took the answer to request `requestId` (it gave the request up): what it carried is queued. */
  async dropped(requestId: number): Promise<void> {
    for (const [ref, issued] of this.#issued)
      if (issued.requestId === requestId) await this.#settle(ref);
  }

  /**
   * The core's process went. The gate keeps what the core last confirmed, read only; every bearer the core had not
   * settled is queued for revocation (or revoked at the server), and every Google window it opened shows failure.
   */
  async coreExited(): Promise<void> {
    for (const complete of this.#grants.values()) complete(false);
    this.#grants.clear();
    for (const ref of Array.from(this.#issued.keys())) await this.#settle(ref);
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#gate.close();
    await this.coreExited();
    if (this.#issued.size > 0)
      throw new Error(
        "Electron Main closed with an issued credential that could not be quarantined."
      );
  }

  // --- Custody -------------------------------------------------------------------------------------------------------

  /** Takes a bearer out of an auth answer: kept here, the core answered its reference (`credential`). */
  #keepBearer(body: Uint8Array, requestId: number | undefined): Uint8Array {
    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return body;
    }
    if (typeof value !== "object" || value === null || !("token" in value)) return body;
    const { token, ...rest } = value as Record<string, unknown> & { token: unknown };
    if (typeof token !== "string" || token.length === 0)
      return new TextEncoder().encode(JSON.stringify(rest));
    // A bearer the store already keeps (a probe that reflected it) is named, not taken into custody again.
    const stored = this.#store.getVaultSnapshot();
    if (
      stored.status === "readable" &&
      (stored.active?.token === token ||
        stored.pendingRevocations.some((pending) => pending.token === token))
    )
      return new TextEncoder().encode(
        JSON.stringify({ ...rest, credential: this.#refFor(token) })
      );
    const identity = issuedIdentitySchema.safeParse(rest);
    const credential = identity.success
      ? secureSessionActiveCredentialSchema.safeParse({
          audience: this.#trustedAudience,
          email: identity.data.user.email,
          expiresAtEpochSeconds: identity.data.expires_at,
          sessionId: identity.data.session_id,
          token,
          userId: identity.data.user.id,
        })
      : undefined;
    const ref = this.#refFor(token);
    this.#issued.set(ref, {
      token,
      ...(credential?.success ? { credential: credential.data } : {}),
      ...(identity.success ? { sessionId: identity.data.session_id } : {}),
      ...(requestId !== undefined ? { requestId } : {}),
    });
    return new TextEncoder().encode(JSON.stringify({ ...rest, credential: ref }));
  }

  /**
   * Queues an issued bearer for revocation. The active credential of the session the core shows signed in stays
   * (a probe that reflected it); any other is queued.
   */
  async #quarantine(ref: string): Promise<boolean> {
    const issued = this.#issued.get(ref);
    const token = issued?.token ?? this.#tokenFor(ref);
    if (!token) return false;
    const snapshot = this.#gate.getSnapshot();
    const vault = this.#store.getVaultSnapshot();
    if (
      snapshot.phase === "signed_in" &&
      vault.status === "readable" &&
      vault.active?.token === token &&
      vault.active.sessionId === snapshot.session.sessionId
    ) {
      this.#issued.delete(ref);
      return true;
    }
    if (!issued && !this.#committed.has(ref)) {
      // A credential the store already keeps, named by the core (a reflected bearer): nothing to queue.
      return (
        vault.status === "readable" &&
        (vault.active?.token === token ||
          vault.pendingRevocations.some((pending) => pending.token === token))
      );
    }
    const sessionId =
      issued?.sessionId ??
      (vault.status === "readable" && vault.active?.token === token
        ? vault.active.sessionId
        : undefined);
    let queued = false;
    try {
      // Queuing the active credential (a sign-in whose commit a newer one overtook) removes it from the store.
      queued =
        (await this.#store.queueRevocation({
          audience: this.#trustedAudience,
          ...(sessionId ? { sessionId } : {}),
          token,
        })) === true;
    } catch {
      queued = false;
    }
    if (queued) {
      this.#issued.delete(ref);
      this.#committed.delete(ref);
    }
    return queued;
  }

  /** Settles a bearer the core left: queued, or else revoked at the server; kept while neither works. */
  async #settle(ref: string): Promise<void> {
    if (await this.#quarantine(ref)) return;
    const issued = this.#issued.get(ref);
    if (!issued) return;
    try {
      const response = await this.#fetch(
        new URL("/v1/comma/auth/logout", this.#trustedAudience),
        {
          body: "{}",
          credentials: "omit",
          headers: {
            accept: "application/json",
            authorization: `Bearer ${issued.token}`,
            "content-type": "application/json",
            "x-comma-session-transport": "bearer",
          },
          method: "POST",
          redirect: "manual",
          // A server that never answers must not hold Main's close.
          signal: AbortSignal.timeout(5_000),
        }
      );
      if (response.ok || response.status === 401) this.#issued.delete(ref);
    } catch {
      // Kept: the next sweep (or close) tries again.
    }
  }

  #refFor(token: string): string {
    let ref = this.#refs.get(token);
    if (!ref) {
      ref = `cred_${randomUUID()}`;
      this.#refs.set(token, ref);
      this.#tokens.set(ref, token);
    }
    return ref;
  }

  #tokenFor(ref: string): string | undefined {
    return this.#issued.get(ref)?.token ?? this.#tokens.get(ref);
  }

  #view(vault: SecureSessionVaultSnapshot): BearerVault {
    if (vault.status !== "readable")
      return { problem: vault.problem, status: "indeterminate" };
    const active = vault.active;
    return {
      active: active
        ? {
            audience: active.audience,
            email: active.email,
            expiresAtEpochSeconds: active.expiresAtEpochSeconds,
            ref: this.#refFor(active.token),
            sessionId: active.sessionId,
            userId: active.userId,
          }
        : null,
      cleanup: vault.cleanup,
      pending: vault.pendingRevocations.map((pending) => ({
        audience: pending.audience,
        ref: this.#refFor(pending.token),
        ...(pending.sessionId ? { sessionId: pending.sessionId } : {}),
      })),
      status: "readable",
    };
  }
}

function activeCredential(
  active: SecureSessionVaultActive
): SecureSessionActiveCredential {
  const { credentialVersion: _credentialVersion, ...credential } = active;
  return secureSessionActiveCredentialSchema.parse(credential);
}
