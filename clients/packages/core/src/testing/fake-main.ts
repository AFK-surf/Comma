// Electron's Main as the core's session lifecycle sees it, in memory: the credential store (an active credential and
// the queue of credentials to revoke), the bearers it keeps out of the core (it attaches the one a request names, and
// takes any bearer out of an answer, keeping it and answering a reference), its gate (what the core told it last, and
// whether a request for a lease would be let through), and its Google window. The server behind it is a FakeCommaApi
// whose handlers see the bearer as the real server would (`authorization: Bearer …`). A test makes a store write
// fail, or not commit, with `failNext`.
import { HostError, fromUtf8, toJsonBytes } from "@comma/core-kernel";
import {
  sessionProductLease,
  type SessionCleanup,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import { Effect } from "effect";
import type {
  ApiResponse,
  AppleGrant,
  AuthRequest,
  BearerSessionPorts,
  BearerVault,
  BearerVaultChange,
  CredentialRef,
  GoogleGrant,
  SessionAuthorityResume,
  SessionLease,
} from "../host.ts";
import { type FakeCommaApi, type FakeHost, json, NO_LEASE } from "./index.ts";

/** A credential as Main keeps it: the bearer, and whose it is. */
export interface StoredCredential {
  token: string;
  audience: string;
  sessionId?: string;
  userId?: string;
  email?: string;
  expiresAtEpochSeconds?: number;
}

type ChangeKind = BearerVaultChange["kind"] | "read";

export class FakeMain {
  readonly host: FakeHost;
  readonly api: FakeCommaApi;
  readonly origin: string;
  active: StoredCredential | null = null;
  pending: StoredCredential[] = [];
  /** Bearers taken out of answers, by the reference the core was given, until a change settles them. */
  readonly issued = new Map<CredentialRef, StoredCredential>();
  /** What the core told the gate, in order. */
  readonly told: { snapshot: SessionLifecycleSnapshot; lease: SessionLease | null }[] =
    [];
  /** The Google window: what it answers when opened (a grant, or a failure). */
  google: (input: {
    clientId: string;
    nonce: string;
  }) => Effect.Effect<GoogleGrant, HostError> = () =>
    Effect.succeed({
      authorizationCode: "google-authorization-code",
      codeVerifier: "google-code-verifier",
      redirectUri: "http://127.0.0.1:43123/oauth2/callback",
      grant: "grant-1",
    });
  readonly googleDone: [string, boolean][] = [];
  /** The iPhone's Sign in with Apple sheet (an iOS Main): what it answers when shown. */
  apple: (input: {
    clientId: string;
    nonce: string;
  }) => Effect.Effect<AppleGrant, HostError> = () =>
    Effect.succeed({ identityToken: "apple-identity-token" });
  /** Issued bearers the core committed: quarantining one again (a sign-in it overtook) takes it out of the store. */
  readonly #committed = new Set<CredentialRef>();
  readonly #refs = new Map<string, CredentialRef>();
  #nextRef = 1;
  readonly #failures: {
    kind: ChangeKind;
    outcome: "fail" | "refuse" | "hang";
    held?: Promise<void>;
    after?: "fail";
  }[] = [];
  /** Every change asked for (and reads), in order. */
  readonly changes: ChangeKind[] = [];

  constructor(
    host: FakeHost,
    options: {
      origin?: string;
      resumed?: SessionAuthorityResume;
      clientPlatform?: BearerSessionPorts["clientPlatform"];
      showsKeptAccount?: boolean;
      clientKind?: BearerSessionPorts["clientKind"];
    } = {}
  ) {
    this.host = host;
    this.api = host.api;
    this.origin = options.origin ?? "https://api.comma.test";
    const ports: BearerSessionPorts = {
      apiOrigin: this.origin,
      clientPlatform: options.clientPlatform ?? "macos",
      ...(options.resumed ? { resumed: options.resumed } : {}),
      ...(options.showsKeptAccount ? { showsKeptAccount: true } : {}),
      ...(options.clientKind ? { clientKind: options.clientKind } : {}),
      vault: this.#change("read", () => this.vault()).pipe(
        Effect.filterOrFail(
          (vault) => vault !== null,
          () => new HostError("the store could not be read")
        )
      ),
      change: (change) => this.#change(change.kind, () => this.#apply(change)),
      gate: (snapshot, lease) => {
        this.told.push({
          snapshot: structuredClone(snapshot),
          lease: lease ? { ...lease } : null,
        });
      },
      ...(options.clientKind === "ios"
        ? { apple: (input) => this.apple(input) }
        : {
            google: (input) => this.google(input),
            googleDone: (grant, ok) =>
              Effect.sync(() => void this.googleDone.push([grant, ok])),
          }),
    };
    host.bearerSession = ports;
    host.authFetch = (request) => this.authFetch(request);
    // The core's product requests go through Main's `/v1` proxy: refused unless the gate is open for their lease.
    const answer = host.fetch.bind(host);
    host.fetch = (request) =>
      this.admits(request.lease)
        ? answer(request)
        : Effect.succeed(
            json(409, {
              error: {
                code: "session_product_lease_unavailable",
                recovery: { authorityInstanceId: "main", generation: 0, revision: 0 },
              },
            })
          );
  }

  /** The next `kind` change (or `read`) fails (`fail`: its outcome unknown), changes nothing (`refuse`), or waits. */
  failNext(kind: ChangeKind, outcome: "fail" | "refuse" = "fail"): void {
    this.#failures.push({ kind, outcome });
  }

  /** The next `kind` change waits until the returned function is called (then is made, or with `fail` fails). */
  holdNext(kind: ChangeKind, after?: "fail"): () => void {
    let release!: () => void;
    const held = new Promise<void>((resolve) => (release = resolve));
    this.#failures.push({ kind, outcome: "hang", held, ...(after ? { after } : {}) });
    return () => release();
  }

  /** The gate as Main would apply it now: the lease it lets requests through for, if any. */
  gateLease(): SessionLease | null {
    return this.told.at(-1)?.lease ?? null;
  }

  /** Whether any bearer Main holds appears in `text` (what the core was told or sent). */
  leaks(text: string): string[] {
    const tokens = [
      this.active?.token,
      ...this.pending.map((p) => p.token),
      ...[...this.issued.values()].map((c) => c.token),
      ...this.#refs.keys(),
    ].filter((t): t is string => Boolean(t));
    return tokens.filter((token) => text.includes(token));
  }

  vault(): BearerVault {
    return {
      status: "readable",
      active:
        this.active && this.active.sessionId && this.active.userId
          ? {
              ref: this.#ref(this.active.token),
              audience: this.active.audience,
              sessionId: this.active.sessionId,
              userId: this.active.userId,
              email: this.active.email ?? "",
              expiresAtEpochSeconds: this.active.expiresAtEpochSeconds ?? 1,
            }
          : null,
      pending: this.pending.map((p) => ({
        ref: this.#ref(p.token),
        audience: p.audience,
        ...(p.sessionId ? { sessionId: p.sessionId } : {}),
      })),
      cleanup: this.cleanup(),
    };
  }

  cleanup(): SessionCleanup {
    return this.pending.length > 0
      ? { revocation: "pending", pendingCount: this.pending.length }
      : { revocation: "idle" };
  }

  authFetch(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    const credential = request.credential ? this.#token(request.credential) : undefined;
    if (request.credential && !credential)
      return Effect.fail(new HostError("the credential named is not kept"));
    return this.api
      .answer({
        method: request.method,
        path: request.path,
        headers: [
          ...request.headers,
          ["x-comma-session-transport", "bearer"],
          ...(credential
            ? ([["authorization", `Bearer ${credential.token}`]] as [string, string][])
            : []),
        ],
        body: request.body,
        lease: NO_LEASE,
      })
      .pipe(Effect.map((response) => this.#keepBearer(response)));
  }

  /** Takes a bearer out of an answer: kept here, the core told its reference. */
  #keepBearer(response: ApiResponse): ApiResponse {
    let body: unknown;
    try {
      body = JSON.parse(fromUtf8(response.body));
    } catch {
      return response;
    }
    if (typeof body !== "object" || body === null || !("token" in body))
      return response;
    const { token, ...rest } = body as Record<string, unknown> & { token: unknown };
    if (typeof token !== "string") return { ...response, body: toJsonBytes(rest) };
    // A bearer the store already keeps (a probe that reflected it) is named, not taken into custody again.
    if (this.active?.token === token || this.pending.some((p) => p.token === token))
      return {
        ...response,
        body: toJsonBytes({ ...rest, credential: this.#ref(token) }),
      };
    const projection = rest as {
      session_id?: string;
      expires_at?: number;
      user?: { id?: string; email?: string };
    };
    const ref = this.#ref(token);
    this.issued.set(ref, {
      token,
      audience: this.origin,
      ...(projection.session_id ? { sessionId: projection.session_id } : {}),
      ...(projection.user?.id ? { userId: projection.user.id } : {}),
      ...(projection.user?.email ? { email: projection.user.email } : {}),
      ...(projection.expires_at
        ? { expiresAtEpochSeconds: projection.expires_at }
        : {}),
    });
    return { ...response, body: toJsonBytes({ ...rest, credential: ref }) };
  }

  #ref(token: string): CredentialRef {
    let ref = this.#refs.get(token);
    if (!ref) {
      ref = `cred-${this.#nextRef++}`;
      this.#refs.set(token, ref);
    }
    return ref;
  }

  #token(ref: CredentialRef): StoredCredential | undefined {
    const issued = this.issued.get(ref);
    if (issued) return issued;
    if (this.active && this.#ref(this.active.token) === ref) return this.active;
    return this.pending.find((p) => this.#ref(p.token) === ref);
  }

  #change<A>(kind: ChangeKind, apply: () => A): Effect.Effect<A | null, HostError> {
    return Effect.suspend(() => {
      this.changes.push(kind);
      const at = this.#failures.findIndex((f) => f.kind === kind);
      if (at < 0) return Effect.sync(apply);
      const [failure] = this.#failures.splice(at, 1);
      const failed = Effect.fail(new HostError(`the store's ${kind} failed`));
      if (failure!.outcome === "fail") return failed;
      if (failure!.outcome === "refuse") return Effect.succeed(null);
      return Effect.promise(() => failure!.held!).pipe(
        Effect.andThen(failure!.after === "fail" ? failed : Effect.sync(apply))
      );
    });
  }

  #apply(change: BearerVaultChange): BearerVault | boolean | null {
    switch (change.kind) {
      case "commit": {
        const credential = this.issued.get(change.issued);
        if (!credential) return null;
        for (const ref of change.supersede) {
          const superseded = this.issued.get(ref);
          if (superseded && superseded.token !== credential.token) {
            this.#queue(superseded);
            this.issued.delete(ref);
          }
        }
        if (this.active && this.active.token !== credential.token)
          this.#queue(this.active);
        this.active = credential;
        this.issued.delete(change.issued);
        this.#committed.add(change.issued);
        return this.vault();
      }
      case "adopt": {
        if (!this.active || this.#ref(this.active.token) !== change.active) return null;
        this.active = { ...this.active, ...change.identity };
        return this.vault();
      }
      case "invalidate": {
        if (!this.active || this.#ref(this.active.token) !== change.active) return null;
        this.active = null;
        return this.vault();
      }
      case "signOut": {
        if (this.active) this.#queue(this.active);
        this.active = null;
        return this.vault();
      }
      case "quarantine": {
        const credential = this.issued.get(change.issued) ?? this.#token(change.issued);
        if (!credential) return false;
        this.issued.delete(change.issued);
        const told = this.snapshot();
        // The session the core shows signed in keeps its credential.
        if (
          this.active?.token === credential.token &&
          told?.phase === "signed_in" &&
          told.session.sessionId === this.active.sessionId
        )
          return true;
        if (
          this.active?.token === credential.token &&
          !this.#committed.has(change.issued)
        )
          return true;
        if (this.active?.token === credential.token) this.active = null;
        this.#committed.delete(change.issued);
        this.#queue(credential);
        return true;
      }
      case "release":
        this.issued.delete(change.issued);
        return this.vault();
      case "revoked":
        this.pending = this.pending.filter(
          (p) => this.#ref(p.token) !== change.pending
        );
        return this.vault();
      case "retainAudience":
        if (this.active && this.active.audience !== this.origin) this.active = null;
        this.pending = this.pending.filter((p) => p.audience === this.origin);
        return this.vault();
    }
  }

  #queue(credential: StoredCredential): void {
    if (this.pending.some((p) => p.token === credential.token)) return;
    this.pending.push({
      token: credential.token,
      audience: credential.audience,
      ...(credential.sessionId ? { sessionId: credential.sessionId } : {}),
    });
  }

  /** Whether Main would let a request for `lease` through now (its gate is open for exactly that lease). */
  admits(lease: SessionLease): boolean {
    const open = this.gateLease();
    return (
      open !== null &&
      open.authorityInstanceId === lease.authorityInstanceId &&
      open.generation === lease.generation &&
      open.sessionId === lease.sessionId &&
      open.audience === lease.audience
    );
  }

  /** The snapshot Main shows its consumers: the last one the core told it. */
  snapshot(): SessionLifecycleSnapshot | undefined {
    return this.told.at(-1)?.snapshot;
  }

  /** Main's gate as it would hand a restarted core (`BearerSessionPorts.resumed`). */
  resume(): SessionAuthorityResume | undefined {
    const last = this.told.at(-1);
    if (!last) return undefined;
    return {
      authorityInstanceId: last.snapshot.authority.authorityInstanceId,
      generation: last.snapshot.generation,
      revision: last.snapshot.revision,
      sessionId: last.lease
        ? (sessionProductLease(last.snapshot)?.sessionId ?? null)
        : null,
    };
  }
}
