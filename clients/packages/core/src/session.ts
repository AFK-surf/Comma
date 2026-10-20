// The session as the core knows it, and the account it opens for it. Who says what the session is: Electron's Main
// (the host tells the core each change), on the web the core's own lifecycle (session/web-lifecycle.ts). The core
// holds no credential: it knows which session and account it works for, and each request names that session, so the
// host refuses one made for a session that is gone.
//
// When the session changes to another account, or signs out, what the core kept for the account it had is closed and
// deleted from this device, and work under way for it finds it closed (its late answers are not kept). A new
// generation of the same session (Main renewed it) keeps the account.
import { CoreError, type Runner, type Scoped } from "@comma/core-kernel";
import {
  sessionLifecycleSnapshotSchema,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import { Deferred, Effect, Exit, Result, Scope } from "effect";
import { Account, accountDbName } from "./account.ts";
import type { SessionAttempt, SessionEmailCooldown, SessionValue } from "./contract.ts";
import type { Host, SessionLease } from "./host.ts";

type Opened = {
  key: string;
  scoped: Scoped;
  account: Deferred.Deferred<Account, CoreError>;
  ready: Account | null;
};

/** What the core's lifecycle shows besides the session: the sign-in under way, an address told to wait, imports. */
export type SessionView = {
  attempt: SessionAttempt | null;
  emailCooldown: SessionEmailCooldown | null;
  guestImports: number;
};

export class Session {
  readonly #host: Host;
  readonly #runner: Runner;
  #value: SessionValue = { phase: "unknown" };
  #lease: SessionLease | null = null;
  #opened: Opened | null = null;
  #rejected: SessionValue["rejected"];
  #snapshot: SessionLifecycleSnapshot | undefined;
  /** What the lease was given for (the core's lifecycle: its gate and Cookie): another key, another lease. */
  #leaseKey: string | null = null;
  #view: SessionView | undefined;
  /** The account open now was opened from a stored credential the server has not confirmed yet (`keep`). */
  #provisional = false;
  readonly #listeners = new Set<() => void>();
  #withheld = false;
  readonly #rejections = new Set<(lease: SessionLease, status: 401 | 409) => void>();
  /** Done when a lease the core's lifecycle gave closes: its requests under way are stopped. */
  readonly #closings = new WeakMap<SessionLease, Deferred.Deferred<void>>();

  readonly #now: () => number;

  constructor(host: Host, runner: Runner, now: () => number) {
    this.#host = host;
    this.#runner = runner;
    this.#now = now;
  }

  /** The `session` topic's value. */
  value(): SessionValue {
    return {
      ...this.#value,
      ...(this.#rejected ? { rejected: this.#rejected } : {}),
      ...(this.#snapshot ? { lifecycle: this.#snapshot } : {}),
      ...this.#view,
    };
  }

  /** The lease requests go out with now (null while none may): the same object for as long as it is the same lease. */
  lease(): SessionLease | null {
    return this.#lease;
  }

  /** Which account the core works for now (null for none): what changes when the person signed in changes. */
  accountKey(): string | null {
    return this.#opened?.key ?? null;
  }

  /** Called after each change of the session or its account. */
  onChange(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  #changed(): void {
    for (const listener of this.#listeners) listener();
  }

  /** The session as its authority says it now. A snapshot that is no session's is refused. */
  observe(raw: unknown): void {
    const parsed = sessionLifecycleSnapshotSchema.safeParse(raw);
    if (!parsed.success) throw CoreError.invalid("not a session snapshot");
    this.#apply(parsed.data, "observed");
  }

  /**
   * The session as the core's lifecycle published it. `gate` is the product lease it gives (null: none, while it
   * finds out): a new one is a new lease object, even for the same session. `view` is what the UI shows besides.
   */
  applyLifecycle(
    snapshot: SessionLifecycleSnapshot,
    gate: string | null,
    view: SessionView
  ): void {
    this.#view = view;
    const before = this.#lease;
    this.#apply(snapshot, gate);
    // The lifecycle closed the lease (or gave another): what is under way with it stops, as the adapter's lease signal
    // aborted it.
    if (before !== null && before !== this.#lease)
      Effect.runSync(Deferred.succeed(this.#closing(before), undefined));
  }

  #closing(lease: SessionLease): Deferred.Deferred<void> {
    let closing = this.#closings.get(lease);
    if (!closing) {
      // The lifecycle calls in synchronously, so the deferred is made outside a fiber (as before the Effect rules).
      // @effect-diagnostics-next-line preferUnsafeConstructor:off
      closing = Effect.runSync(Deferred.make<void>());
      this.#closings.set(lease, closing);
    }
    return closing;
  }

  /**
   * Waits until `lease` is closed by the core's lifecycle (the web): a request made with it is stopped then. A lease
   * the host's authority gave (Electron's Main) never closes here: the host refuses it itself.
   */
  closed(lease: SessionLease): Effect.Effect<void> {
    return Deferred.await(this.#closing(lease));
  }

  /** Told when the server refused a request for the current lease (the core's lifecycle invalidates it). */
  onRejected(listener: (lease: SessionLease, status: 401 | 409) => void): () => void {
    this.#rejections.add(listener);
    return () => this.#rejections.delete(listener);
  }

  /**
   * The account a stored credential names, before the server confirmed its session (a host that shows what it kept
   * while the session is checked, and offline: `BearerSessionPorts.showsKeptAccount`). What the device keeps for it is
   * opened and shown; no lease is given, so no request goes out. The check that follows confirms it (the account
   * stays, with its lease), ends it (closed and deleted), or cannot reach the server (it stays shown, without a lease).
   */
  keep(identity: { audience: string; sessionId: string; userId: string }): void {
    if (this.#opened !== null || this.#value.phase !== "unknown") return;
    this.#provisional = true;
    this.#value = { phase: "signed_in", ...identity };
    this.#open(`${identity.audience}\n${identity.userId}`, identity.userId, {
      audience: identity.audience,
      authorityInstanceId: "",
      generation: 0,
      sessionId: identity.sessionId,
    });
    this.#changed();
  }

  #apply(snapshot: SessionLifecycleSnapshot, gate: string | null): void {
    this.#snapshot = snapshot;
    if (snapshot.phase === "signed_in") {
      this.#provisional = false;
      const fresh: SessionLease = {
        audience: snapshot.session.audience,
        authorityInstanceId: snapshot.authority.authorityInstanceId,
        generation: snapshot.generation,
        sessionId: snapshot.session.sessionId,
      };
      const kept = this.#lease;
      const lease =
        gate === null
          ? null
          : kept !== null &&
              this.#leaseKey === gate &&
              kept.audience === fresh.audience &&
              kept.authorityInstanceId === fresh.authorityInstanceId &&
              kept.generation === fresh.generation &&
              kept.sessionId === fresh.sessionId
            ? kept
            : fresh;
      this.#leaseKey = gate;
      const key = `${fresh.audience}\n${snapshot.principal.userId}`;
      const sameAccount = this.#opened?.key === key;
      if (!sameAccount) this.#close();
      this.#lease = lease;
      this.#withheld = false;
      this.#value = {
        phase: "signed_in",
        userId: snapshot.principal.userId,
        audience: fresh.audience,
        sessionId: fresh.sessionId,
      };
      if (this.#rejected && this.#rejected.sessionId !== fresh.sessionId)
        this.#rejected = undefined;
      if (!sameAccount) this.#open(key, snapshot.principal.userId, fresh);
      this.#changed();
      return;
    }
    this.#leaseKey = null;
    if (snapshot.phase === "signed_out") {
      this.#provisional = false;
      this.#close();
      this.#lease = null;
      this.#withheld = false;
      this.#value = { phase: "signed_out" };
      this.#changed();
      return;
    }
    // Under way (signing in or out, starting) or undecided: no request goes out, what is kept stays.
    // While signing out, or when a sign-out ended undecided, it is not shown either (`withheld`). The lifecycle's
    // snapshot changed even when these did not, so the `session` topic is told.
    this.#lease = null;
    // A kept account whose check could not reach the server stays shown: nothing ended it.
    const keptOffline =
      this.#provisional &&
      snapshot.phase === "indeterminate" &&
      snapshot.problem.code === "session_probe_unavailable";
    this.#withheld =
      snapshot.phase !== "initializing" &&
      snapshot.phase !== "authenticating" &&
      !keptOffline;
    this.#changed();
  }

  /** Whether what the account keeps is withheld from the UIs: a sign-out is under way or ended undecided. */
  withheld(): boolean {
    return this.#withheld;
  }

  /**
   * Opens the account's database (its file, or one in memory when the file cannot be opened: another app holds it) in
   * a scope of its own. Closing that scope (the account let go, or the core) closes the account, one still opening
   * once it opens; whoever waits for it finds no one signed in.
   */
  #open(key: string, userId: string, lease: SessionLease): void {
    const scoped = this.#runner.child();
    // The lifecycle calls in synchronously, so the deferred is made outside a fiber (as before the Effect rules).
    // @effect-diagnostics-next-line preferUnsafeConstructor:off
    const account = Effect.runSync(Deferred.make<Account, CoreError>());
    const opened: Opened = { key, scoped, account, ready: null };
    this.#opened = opened;
    const name = accountDbName(lease.audience, userId);
    const host = this.#host;
    const open = Effect.gen(function* () {
      const file = yield* Effect.result(host.openDb(name));
      if (Result.isSuccess(file))
        return new Account(userId, lease, name, file.success, false);
      console.error(
        "comma core: the account's database did not open; keeping this run's data in memory",
        file.failure
      );
      return new Account(
        userId,
        lease,
        name,
        yield* host.memoryDb.pipe(Effect.mapError((e) => CoreError.host(e.message))),
        true
      );
    });
    Effect.runSync(
      Scope.addFinalizer(scoped.scope, Deferred.fail(account, signedOut()))
    );
    this.#runner.fork(
      Effect.acquireRelease(open, (opening) => Effect.sync(() => opening.close())).pipe(
        Scope.provide(scoped.scope),
        Effect.matchEffect({
          onSuccess: (ready) =>
            Effect.sync(() => {
              opened.ready = ready;
            }).pipe(Effect.andThen(Deferred.succeed(account, ready))),
          onFailure: () =>
            Deferred.fail(
              account,
              new CoreError("storage", "The account's data could not be opened.")
            ),
        }),
        Effect.andThen(Effect.sync(() => this.#changed()))
      ),
      scoped
    );
  }

  /**
   * Lets the account go (another account, or none): closed, and deleted from this device once closed when it was open.
   * One still opening is not deleted: another may open the same file by then.
   */
  #close(): void {
    const opened = this.#opened;
    if (!opened) return;
    this.#opened = null;
    const host = this.#host;
    this.#runner.fork(
      Scope.close(opened.scoped.scope, Exit.void).pipe(
        Effect.andThen(
          Effect.suspend(() => {
            const ready = opened.ready;
            return ready && !ready.inMemory ? host.deleteDb(ready.dbName) : Effect.void;
          })
        ),
        Effect.ignore
      )
    );
  }

  /**
   * Lets the account go and closes its database, without deleting it (the app is being reset: its host deletes every
   * database). Done once it is closed; requests under way for it find it closed.
   */
  release(): Effect.Effect<void> {
    return Effect.suspend(() => {
      const opened = this.#opened;
      if (!opened) return Effect.void;
      this.#opened = null;
      this.#lease = null;
      return Scope.close(opened.scoped.scope, Exit.void);
    });
  }

  /** The signed-in account, once its database is open; fails `signed_out` while there is none. */
  account(): Effect.Effect<Account, CoreError> {
    return Effect.suspend(() => {
      const opened = this.#opened;
      if (!opened || this.#lease === null) return Effect.fail(signedOut());
      const lease = this.#lease;
      return Deferred.await(opened.account).pipe(
        Effect.flatMap((account) => {
          if (account.closed) return Effect.fail(signedOut());
          // Requests go out for the session as it is now (a new generation of the same one).
          account.lease = lease;
          return Effect.succeed(account);
        })
      );
    });
  }

  /** The account open now, if there is one: what a topic reads synchronously. */
  current(): Account | null {
    const ready = this.#opened?.ready ?? null;
    return ready && !ready.closed ? ready : null;
  }

  /** The server refused a request for `lease`'s session: the session's authority hears of it (the `session` topic). */
  rejected(lease: SessionLease, status: 401 | 409): void {
    // A late answer for a lease that is no longer the current one (replaced, or closed) says nothing of this one.
    if (this.#lease !== lease) return;
    this.#rejected = { sessionId: lease.sessionId, status, at: this.#now() };
    for (const listener of this.#rejections) listener(lease, status);
    this.#changed();
  }
}

export function signedOut(): CoreError {
  return new CoreError("signed_out", "No one is signed in.");
}
