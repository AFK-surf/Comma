// Stations: the machines a Comma workspace enrolled, reached from this device directly. The control plane says who
// the account is to them and in which workspaces (`stationsHome`, read once while shown), which stations each
// workspace has and whether each is connected to Comma (`stations`, kept current by the workspace's station events),
// and signs the member credential a station takes. The station itself is reached over this device's own endpoint on
// the mesh (`comma/mesh/1`, host.ts `StationMeshPorts`): one connection per station, which the `stations` topic keeps
// open while it is shown (on a host that stays on, always.ts keeps it whether shown or not) and opens again after it
// went (1 s, 5 s, then every 30 s); while it is open, its row says how it runs (direct, an iroh relay or Salix), as the
// endpoint tells each change. An endpoint that can be reached through Salix, the relay of last resort, also
// keeps a socket to Comma's client relay for each shown workspace with stations, opened with a single-use ticket and
// again after it went (Salix closes it after an hour).
//
// Bounds: one control-plane read of the account per showing; per shown workspace one list read, one event stream and
// one connection per listed station (the control plane bounds how many a workspace has); one credential request per
// workspace a day (less when the session ends sooner), and one more when a station refuses the credential kept (a
// station that refuses a new one too gets no other until it admits one); per shown workspace with stations one relay
// socket, and a ticket for each socket opened (two a minute while none lasts). The endpoint is bound only while some
// workspace's stations are kept (shown, or always.ts), and closed when the account changes.
//
// The account's database keeps each workspace's stations (`station`) and its credential (`station_cred`, until it
// expires by the core's clock or a station refuses it): after a restart, stations are reached with them before the
// control plane answers, or while it does not.
import {
  CoreError,
  type HostError,
  type Scoped,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Deferred, Effect, Exit, Result, Scope, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import type {
  StationEnrollment,
  StationLinkState,
  StationRow,
  StationVia,
  StationsHomeValue,
  StationsValue,
  StationToolsAccess,
} from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import { header, stationRefused, type Pull, type StationLinks } from "../host.ts";
import { readEvents } from "../sse.ts";
import {
  credentialPath,
  credentialSchema,
  enrollmentSchema,
  enrollmentsPath,
  eventsPath,
  listPath,
  listSchema,
  mePath,
  meSchema,
  presenceEventSchema,
  relayPath,
  relayTicketSchema,
  stationPath,
  stationSchema,
  type IssuedCredential,
  type ListedStation,
  type Me,
} from "./control.ts";
import type { StationNamed, Viewer } from "./views.ts";

/** Pauses before a connection, or the event stream, is opened again. */
const RETRY_MS = [1_000, 5_000, 30_000];
/** A request to a station, or a connection being opened, gives up after this long. */
const STATION_TIMEOUT_MS = 30_000;
/** A credential is asked for again this long before it expires. */
const CREDENTIAL_MARGIN_MS = 60_000;
/** The most of a station's answer read. */
const MAX_ANSWER_BYTES = 4 * 1024 * 1024;
/** A file the station gives (`file`) may take this long: it is bounded by size, not by the link's speed. */
const FILE_TIMEOUT_MS = 600_000;
/** A relay socket open this long was carrying: the next opens after the shortest pause. */
const RELAY_LASTED_MS = 60_000;
/** Where this device's endpoint key is kept (device storage: the same device whoever is signed in). */
const KEY = "stations.endpointKey";

const ME_DOC = "stations.me";

const accessSchema = z.object({ access: z.enum(["off", "read", "full"]) });

type Link = { state: StationLinkState; message?: string; via?: StationVia };

type Shown = {
  /** Who keeps it shown: the `stations` topic, or another view of the workspace's stations. */
  holders: Set<string>;
  scoped: Scoped;
  loading: boolean;
  error: string | undefined;
  /** Each station's connection fiber, by id, while it is listed. */
  linked: Map<string, Scoped>;
  /** The relay socket's fiber, while some station is listed. */
  relayed: Scoped | null;
};

type Mesh = {
  scoped: Scoped;
  links: Deferred.Deferred<StationLinks, CoreError>;
};

const params = {
  string(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  access(raw: unknown): StationToolsAccess {
    const v = (raw as Record<string, unknown> | null)?.access;
    if (v !== "off" && v !== "read" && v !== "full")
      throw CoreError.invalid("access is off, read or full");
    return v;
  },
};

export class Stations {
  readonly #ctx: Ctx;
  #accountKey: string | null = null;
  #home: { loading: boolean; error: string | undefined } = {
    loading: false,
    error: undefined,
  };
  readonly #shown = new Map<string, Shown>();
  readonly #links = new Map<string, Link>();
  /** Which workspace each listed station is in: its credential is that workspace's. */
  readonly #workspaceOf = new Map<string, string>();
  readonly #credentialLock = Semaphore.makeUnsafe(1);
  /** Stations that refused a newly issued credential and have admitted none since (`#admitted`). */
  readonly #refusing = new Set<string>();
  #mesh: Mesh | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const { kernel } = ctx;
    kernel.source("stationsHome", {
      start: () => this.#readHome(),
      stop: () => {},
      compute: (): Value => ({ ok: this.#homeValue() }),
    });
    kernel.source("stations", {
      start: (topic) => this.retain(topic.workspace as string, "stations"),
      stop: (topic) => this.release(topic.workspace as string, "stations"),
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing of one account is used for another: its connections and what was shown go (what it kept is in its
      // own database).
      this.#closeMesh();
      this.#refusing.clear();
      this.#workspaceOf.clear();
      this.#links.clear();
      this.#home = { loading: false, error: undefined };
      const shown = [...this.#shown].map(
        ([workspace, s]) => [workspace, [...s.holders]] as const
      );
      for (const [workspace, holders] of shown)
        for (const holder of holders) this.release(workspace, holder);
      for (const listener of this.#accountListeners) listener();
      kernel.store.invalidate({ topic: "stationsHome" });
      if (kernel.store.liveTopics().some((t) => t.topic === "stationsHome"))
        this.#readHome();
      for (const [workspace, holders] of shown) {
        for (const holder of holders) this.retain(workspace, holder);
        this.#changed(workspace);
      }
    });

    kernel.calls({
      "stations.enroll": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const name = (p as { name?: unknown } | null)?.name;
          if (name !== undefined && (typeof name !== "string" || name.length > 200))
            throw CoreError.invalid("name is at most 200 characters");
          return this.#control((account) =>
            ctx.api.request(
              account,
              "POST",
              enrollmentsPath(workspace),
              enrollmentSchema,
              name ? { name } : {}
            )
          ).pipe(
            Effect.map(
              (e): StationEnrollment => ({
                token: e.token,
                command: e.command,
                expiresAt: e.expires_at,
              })
            )
          );
        },
      },
      "stations.rename": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const station = params.string(p, "station");
          const name = params.string(p, "name", 200).trim();
          if (name === "") throw CoreError.invalid("name is required");
          return this.#control((account) =>
            ctx.api
              .request(
                account,
                "PATCH",
                stationPath(workspace, station),
                stationSchema,
                { name }
              )
              .pipe(Effect.tap((row) => this.#patch(account, workspace, row.id, row)))
          ).pipe(Effect.as(null));
        },
      },
      "stations.remove": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const station = params.string(p, "station");
          return this.#control((account) =>
            ctx.api
              .request(account, "DELETE", stationPath(workspace, station), z.unknown())
              .pipe(Effect.andThen(this.#readList(account, workspace)))
          ).pipe(Effect.as(null));
        },
      },
      "stations.toolsAccess": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const station = params.string(p, "station");
          return this.ask(workspace, station, "GET", "/tools/access").pipe(
            Effect.flatMap((answer) => parsed(accessSchema, answer)),
            Effect.map(({ access }) => ({ access }))
          );
        },
      },
      "stations.setToolsAccess": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const station = params.string(p, "station");
          const access = params.access(p);
          return this.ask(workspace, station, "PUT", "/tools/access", { access }).pipe(
            Effect.flatMap((answer) => parsed(accessSchema, answer)),
            Effect.map((answer) => ({ access: answer.access }))
          );
        },
      },
    });
  }

  // ── the account and its workspaces ───────────────────────────────────

  #homeValue(): StationsHomeValue {
    const empty = { account: null, workspaces: [] };
    if (!this.#ctx.host.stationMesh) return { state: "unavailable", ...empty };
    if (this.#ctx.session.value().phase !== "signed_in")
      return { state: "signed_out", ...empty };
    const me = this.#ctx.session.current()?.doc<Me>(ME_DOC)?.value;
    if (me)
      return {
        state: "ready",
        account: me.user,
        workspaces: me.workspaces.map((w) => ({
          id: w.id,
          name: w.name,
          role: w.role,
        })),
      };
    if (this.#home.error !== undefined)
      return { state: "error", reason: this.#home.error, ...empty };
    return { state: "loading", ...empty };
  }

  /** Reads who the account is to its stations; what the device kept shows meanwhile. */
  #readHome(): void {
    if (!this.#ctx.host.stationMesh || this.#home.loading) return;
    this.#home.loading = true;
    this.#ctx.runner.fork(
      this.#control((account) => this.#readMe(account)).pipe(
        Effect.match({
          onSuccess: () => (this.#home.error = undefined),
          onFailure: (e) => (this.#home.error = e.message),
        }),
        Effect.ensuring(
          Effect.sync(() => {
            this.#home.loading = false;
            this.#ctx.kernel.store.invalidate({ topic: "stationsHome" });
          })
        )
      )
    );
  }

  #readMe(account: Account): Effect.Effect<Me, CoreError> {
    return this.#ctx.api.request(account, "GET", mePath, meSchema).pipe(
      Effect.tap((me) =>
        Effect.sync(() => {
          if (!account.closed) account.putDoc(ME_DOC, me, this.#ctx.now());
        })
      )
    );
  }

  /** The account's `me`: as kept, else read. */
  #me(account: Account): Effect.Effect<Me, CoreError> {
    const kept = account.doc<Me>(ME_DOC)?.value;
    return kept ? Effect.succeed(kept) : this.#readMe(account);
  }

  // ── a workspace's stations ───────────────────────────────────────────

  /**
   * Keeps `workspace`'s stations shown for `holder`: listed, their presence followed, a connection open to each. The
   * first holder starts it.
   */
  retain(workspace: string, holder: string): void {
    if (!this.#ctx.host.stationMesh) return;
    const held = this.#shown.get(workspace);
    if (held) {
      held.holders.add(holder);
      return;
    }
    const kept = this.#ctx.session.current()?.stationList<ListedStation>(workspace);
    const shown: Shown = {
      holders: new Set([holder]),
      scoped: this.#ctx.runner.child(),
      loading: !kept,
      error: undefined,
      linked: new Map(),
      relayed: null,
    };
    this.#shown.set(workspace, shown);
    if (kept) this.#follow(workspace, kept);
    this.#ctx.runner.fork(
      this.#control((account) =>
        this.#readList(account, workspace).pipe(
          Effect.andThen(this.#presence(account, workspace))
        )
      ).pipe(
        Effect.catch((e: CoreError) =>
          Effect.sync(() => {
            shown.error = e.message;
            shown.loading = false;
            this.#changed(workspace);
          })
        )
      ),
      shown.scoped
    );
  }

  /** `holder` no longer shows `workspace`'s stations: the last one lets them go. */
  release(workspace: string, holder: string): void {
    const shown = this.#shown.get(workspace);
    if (!shown) return;
    shown.holders.delete(holder);
    if (shown.holders.size > 0) return;
    this.#shown.delete(workspace);
    this.#ctx.runner.close(shown.scoped);
    for (const id of shown.linked.keys()) this.#links.delete(id);
    // The endpoint stays only while some workspace's stations are shown.
    if (this.#shown.size === 0) this.#closeMesh();
  }

  #changed(workspace: string): void {
    this.#ctx.kernel.store.invalidate({ topic: "stations", workspace });
    for (const listener of this.#listeners) listener(workspace);
  }

  readonly #listeners = new Set<(workspace: string) => void>();
  readonly #accountListeners = new Set<() => void>();

  /** Told when a workspace's stations, their presence or this device's connections to them changed. */
  onChange(listener: (workspace: string) => void): void {
    this.#listeners.add(listener);
  }

  /** Told when the account changed: everything kept for the one before goes. */
  onAccount(listener: () => void): void {
    this.#accountListeners.add(listener);
  }

  /** The workspace's stations as kept: each with its name and whether it is reached now. */
  named(workspace: string): StationNamed[] {
    const kept =
      this.#ctx.session.current()?.stationList<ListedStation>(workspace) ?? [];
    return kept.map((s) => ({
      id: s.id,
      name: s.name || s.id,
      online: s.online || this.#links.get(s.id)?.state === "online",
    }));
  }

  /** This device's connection to `station`, as it stands. */
  linkOf(station: string): Link {
    return this.#links.get(station) ?? { state: "connecting" };
  }

  /** The viewer as stations know them (their email), once the control plane said. */
  viewer(): Viewer | null {
    const me = this.#ctx.session.current()?.doc<Me>(ME_DOC)?.value;
    return me ? { email: me.user.email } : null;
  }

  #value(topic: Topic): StationsValue {
    const workspace = topic.workspace as string;
    const shown = this.#shown.get(workspace);
    const account = this.#ctx.session.current();
    const kept = account?.stationList<ListedStation>(workspace) ?? [];
    return {
      workspace,
      stations: kept.map(
        (s): StationRow => ({
          id: s.id,
          name: s.name,
          version: s.version,
          present: s.online,
          enrolledAt: s.enrolled_at ?? null,
          enrolledBy: s.enrolled_by ?? null,
          link: this.#links.get(s.id) ?? { state: "connecting" },
        })
      ),
      loading: shown?.loading ?? false,
      ...(shown?.error !== undefined ? { error: shown.error } : {}),
    };
  }

  /** Reads the workspace's stations, keeps them, and follows the listed ones. */
  #readList(account: Account, workspace: string): Effect.Effect<void, CoreError> {
    return this.#ctx.api.request(account, "GET", listPath(workspace), listSchema).pipe(
      Effect.tap(({ stations }) =>
        Effect.sync(() => {
          if (account.closed) return;
          account.putStationList(workspace, stations, this.#ctx.now());
          const shown = this.#shown.get(workspace);
          if (shown) {
            shown.loading = false;
            shown.error = undefined;
          }
          this.#follow(workspace, stations);
          this.#changed(workspace);
        })
      ),
      Effect.asVoid
    );
  }

  /** One station's row changed (renamed, or its presence moved). */
  #patch(
    account: Account,
    workspace: string,
    id: string,
    change: Partial<ListedStation>
  ): Effect.Effect<void> {
    return Effect.sync(() => {
      if (account.closed) return;
      account.updateStation<ListedStation>(
        workspace,
        id,
        (row) => ({ ...row, ...change }),
        this.#ctx.now()
      );
      this.#changed(workspace);
    });
  }

  /** The workspace's station events, while it is shown: presence patches a row, a roster change reads the list. */
  #presence(account: Account, workspace: string): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    let backoff = 0;
    const once = Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const body = yield* ctx.api.stream(account, eventsPath(workspace));
        backoff = 0;
        yield* readEvents(body, (value, event) => {
          if (event === "stations") return this.#readList(account, workspace);
          if (event !== "station") return Effect.void;
          const presence = presenceEventSchema.safeParse(value);
          if (!presence.success) return Effect.void;
          const { id, online, name, version, home_relay, addrs } = presence.data;
          return this.#patch(account, workspace, id, {
            online,
            // Each event says where the station is now: none is none.
            home_relay: home_relay ?? null,
            addrs: addrs ?? null,
            ...(name !== undefined ? { name } : {}),
            ...(version !== undefined ? { version: version ?? null } : {}),
          });
        });
      })
    );
    return Effect.gen(function* () {
      for (;;) {
        yield* Effect.result(once);
        if (account.closed) return;
        // A stream the server ends at once waits too: it must not spin.
        yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
        backoff++;
      }
    });
  }

  /** Keeps a connection to each listed station, and lets go of those no longer listed. */
  #follow(workspace: string, stations: readonly ListedStation[]): void {
    const shown = this.#shown.get(workspace);
    if (!shown) return;
    const listed = new Set(stations.map((s) => s.id));
    for (const [id, scoped] of shown.linked) {
      if (listed.has(id)) continue;
      shown.linked.delete(id);
      this.#links.delete(id);
      this.#workspaceOf.delete(id);
      this.#ctx.runner.close(scoped);
    }
    for (const id of listed) {
      this.#workspaceOf.set(id, workspace);
      if (shown.linked.has(id)) continue;
      const scoped = this.#ctx.runner.child(shown.scoped);
      shown.linked.set(id, scoped);
      this.#ctx.runner.fork(this.#keepLinked(workspace, id), scoped);
    }
    if (listed.size > 0 && !shown.relayed) {
      shown.relayed = this.#ctx.runner.child(shown.scoped);
      this.#ctx.runner.fork(this.#keepRelayed(workspace), shown.relayed);
    } else if (listed.size === 0 && shown.relayed) {
      this.#ctx.runner.close(shown.relayed);
      shown.relayed = null;
    }
  }

  /**
   * Keeps this device's packets carried through Salix to `workspace`'s stations: a ticket, the socket it opens, and
   * again after that went. An endpoint that is not reached through Salix keeps none.
   */
  #keepRelayed(workspace: string): Effect.Effect<void> {
    const ctx = this.#ctx;
    let backoff = 0;
    const once = Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const links = yield* this.#linksNow();
        if (!links.relay) return false;
        const ticket = yield* this.#control((account) =>
          ctx.api.request(account, "POST", relayPath(workspace), relayTicketSchema, {})
        );
        const closed = yield* links
          .relay(workspace, ticket)
          .pipe(Effect.mapError((e) => new CoreError("unavailable", e.message)));
        const registered = ctx.now();
        yield* closed;
        // One that lasted starts the pauses over; one Salix closes at once does not.
        if (ctx.now() - registered >= RELAY_LASTED_MS) backoff = 0;
        return true;
      })
    );
    return Effect.gen(function* () {
      for (;;) {
        const carried = yield* Effect.result(once);
        if (Result.isSuccess(carried) && !carried.success) return;
        // A control plane without the client relay, or one that no longer counts the account a member, has none.
        if (Result.isFailure(carried) && carried.failure.status === 404) return;
        yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
        backoff++;
      }
    });
  }

  /** Shows how the open connection to `station` runs, as it changes (iroh moves it between paths); never ends itself. */
  #followVia(workspace: string, station: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const links = yield* this.#linksNow().pipe(Effect.orElseSucceed(() => null));
      let via: StationVia | null = null;
      for (;;) {
        const next: { via: StationVia | null; closed: boolean } | null = links
          ? yield* links.nextVia(station, via).pipe(Effect.orElseSucceed(() => null))
          : null;
        // The endpoint does not say, or the connection went: its end is the race's other side.
        if (!next || next.closed) return yield* Effect.never;
        via = next.via;
        this.#setLink(
          workspace,
          station,
          via ? { state: "online", via } : { state: "online" }
        );
      }
    });
  }

  #setLink(workspace: string, station: string, link: Link): void {
    const before = this.#links.get(station);
    if (
      before?.state === link.state &&
      before.message === link.message &&
      before.via === link.via
    )
      return;
    this.#links.set(station, link);
    this.#changed(workspace);
  }

  /** Opens the connection to `station`, and again after it went. */
  #keepLinked(workspace: string, station: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      let backoff = 0;
      // While it cannot be reached it shows as offline, with why, through the next tries.
      let next: Link = { state: "connecting" };
      for (;;) {
        this.#setLink(workspace, station, next);
        const opened = yield* Effect.result(
          this.#admitted(station, (links) => links.connect(station)).pipe(
            Effect.timeoutOrElse({
              duration: STATION_TIMEOUT_MS,
              orElse: () =>
                Effect.fail(new CoreError("timeout", "The station did not answer.")),
            })
          )
        );
        if (Result.isSuccess(opened)) {
          backoff = 0;
          this.#setLink(workspace, station, { state: "online" });
          // Open until it closes, saying meanwhile how it runs.
          yield* Effect.raceFirst(opened.success, this.#followVia(workspace, station));
          next = { state: "reconnecting" };
          this.#setLink(workspace, station, next);
        } else {
          next = { state: "offline", message: opened.failure.message };
          this.#setLink(workspace, station, next);
        }
        yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
        backoff++;
      }
    });
  }

  // ── this device's endpoint, and requests to a station ────────────────

  /** The endpoint, bound with this device's key and the control plane's relays the first time it is needed. */
  #linksNow(): Effect.Effect<StationLinks, CoreError> {
    return Effect.suspend(() => {
      const ports = this.#ctx.host.stationMesh;
      if (!ports)
        return Effect.fail(
          new CoreError("unavailable", "This app reaches no station.")
        );
      if (this.#mesh) return Deferred.await(this.#mesh.links);
      const mesh: Mesh = {
        scoped: this.#ctx.runner.child(),
        // Made in the same step that checks `#mesh`, so no second caller opens another mesh.
        // @effect-diagnostics-next-line preferUnsafeConstructor:off
        links: Effect.runSync(Deferred.make<StationLinks, CoreError>()),
      };
      this.#mesh = mesh;
      const open = Effect.gen({ self: this }, function* () {
        const me = yield* this.#control((account) => this.#me(account));
        const secretKey = yield* this.#endpointKey();
        return yield* ports
          .open({ secretKey, relays: me.relay_urls })
          .pipe(Effect.mapError((e) => new CoreError("unavailable", e.message)));
      });
      this.#ctx.runner.fork(
        Effect.exit(open).pipe(
          Effect.tap((exit) => Deferred.done(mesh.links, exit)),
          // Not bound: the next one to need it tries again.
          Effect.tap((exit) =>
            Effect.sync(() => {
              if (Exit.isFailure(exit) && this.#mesh === mesh) this.#closeMesh();
            })
          ),
          Scope.provide(mesh.scoped.scope)
        ),
        mesh.scoped
      );
      return Deferred.await(mesh.links);
    });
  }

  #closeMesh(): void {
    const mesh = this.#mesh;
    if (!mesh) return;
    this.#mesh = null;
    this.#ctx.runner.close(mesh.scoped);
  }

  /** This device's endpoint key: made once, kept in device storage. */
  #endpointKey(): Effect.Effect<Uint8Array, CoreError> {
    const host = this.#ctx.host;
    return host.storageGet(KEY).pipe(
      Effect.flatMap((kept) => {
        if (kept && kept.length === 32) return Effect.succeed(kept);
        const key = new Uint8Array(32);
        host.randomBytes(key);
        return host.storageSet(KEY, key).pipe(Effect.as(key));
      }),
      Effect.mapError((e) => CoreError.host(e))
    );
  }

  /**
   * The endpoint, with a member credential for `station` given to it: its workspace's, for this device, kept in the
   * account's database until shortly before it expires. `issued`: whether that credential was asked of the control
   * plane just now.
   */
  #linkTo(station: string): Effect.Effect<
    {
      links: StationLinks;
      account: Account;
      workspace: string;
      credential: string;
      issued: boolean;
    },
    CoreError
  > {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account();
      const workspace =
        this.#workspaceOf.get(station) ?? account.stationWorkspace(station);
      if (!workspace)
        return yield* Effect.fail(
          new CoreError("not_found", "No such station is listed.")
        );
      const links = yield* this.#linksNow();
      const fresh = () => {
        const kept = account.stationCredential<IssuedCredential>(workspace);
        return kept &&
          kept.device === links.id &&
          kept.expiresAt * 1000 - this.#ctx.now() > CREDENTIAL_MARGIN_MS
          ? kept.value.credential
          : null;
      };
      const given = yield* this.#credentialLock.withPermits(1)(
        Effect.suspend(() => {
          const kept = fresh();
          if (kept) return Effect.succeed({ credential: kept, issued: false });
          return this.#ctx.api
            .request(account, "POST", credentialPath(workspace), credentialSchema, {
              device: links.id,
            })
            .pipe(
              Effect.map((issued) => {
                account.putStationCredential(workspace, {
                  device: links.id,
                  expiresAt: issued.expires_at,
                  value: issued,
                });
                return { credential: issued.credential, issued: true };
              })
            );
        })
      );
      links.credential(station, given.credential);
      const listed = account
        .stationList<ListedStation>(workspace)
        ?.find((s) => s.id === station);
      links.reach(station, {
        relayUrl: listed?.home_relay ?? null,
        addrs: listed?.addrs ?? [],
      });
      return { links, account, workspace, ...given };
    });
  }

  /**
   * `use` of the endpoint, with a member credential given for `station`. A station that refuses a credential this
   * device kept (the control plane changed what it signs since: the workspace's id, its keys) is given a newly issued
   * one and asked once more. A station that refuses a newly issued one is not given another until it has admitted
   * one: each try after that uses what is kept, so a refusing station costs one credential request, not one a try.
   */
  #admitted<A, R>(
    station: string,
    use: (links: StationLinks) => Effect.Effect<A, HostError, R>
  ): Effect.Effect<A, CoreError, R> {
    return Effect.gen({ self: this }, function* () {
      const first = yield* this.#linkTo(station);
      const tried = yield* Effect.result(use(first.links));
      if (Result.isSuccess(tried)) {
        this.#refusing.delete(station);
        return tried.success;
      }
      const refused = () => new CoreError("unreachable", tried.failure.message);
      if (!stationRefused(tried.failure)) return yield* Effect.fail(refused());
      if (first.issued || this.#refusing.has(station)) {
        this.#refusing.add(station);
        return yield* Effect.fail(refused());
      }
      // The kept one goes, unless another station's refusal already replaced it.
      if (
        first.account.stationCredential<IssuedCredential>(first.workspace)?.value
          .credential === first.credential
      )
        first.account.deleteStationCredential(first.workspace);
      const second = yield* this.#linkTo(station);
      return yield* use(second.links).pipe(
        Effect.tap(() => Effect.sync(() => this.#refusing.delete(station))),
        Effect.mapError((e) => {
          if (stationRefused(e)) this.#refusing.add(station);
          return new CoreError("unreachable", e.message);
        })
      );
    });
  }

  /**
   * One request to a station of `workspace`, its JSON answer; a refusal fails with the station's words. A write is sent
   * once (`idempotency-key`): the station answers a repeat as it answered the first.
   */
  ask(
    workspace: string,
    station: string,
    method: string,
    path: string,
    body?: unknown,
    options: {
      /** The write's key, when it is given again (a message sent again). */
      onceKey?: string;
      /** Bytes to send as they are, with their type (an upload), instead of JSON. */
      raw?: { bytes: Uint8Array; type: string };
    } = {}
  ): Effect.Effect<unknown, CoreError> {
    return Effect.gen({ self: this }, function* () {
      if (!this.#workspaceOf.has(station)) this.#workspaceOf.set(station, workspace);
      const headers: [string, string][] = [["accept", "application/json"]];
      if (options.raw) headers.push(["content-type", options.raw.type]);
      else if (body !== undefined) headers.push(["content-type", "application/json"]);
      if (method !== "GET")
        headers.push(["idempotency-key", options.onceKey ?? this.onceKey()]);
      const answered = this.#admitted(station, (links) =>
        links.request(station, {
          method,
          path,
          headers,
          body: options.raw
            ? options.raw.bytes
            : body === undefined
              ? null
              : new TextEncoder().encode(JSON.stringify(body)),
        })
      );
      return yield* Effect.scoped(
        Effect.gen(function* () {
          const response = yield* answered;
          const bytes = yield* collect(
            response.body,
            MAX_ANSWER_BYTES,
            () => new CoreError("bad_response", "The station's answer is too large.")
          );
          const text = new TextDecoder().decode(bytes);
          const value =
            text === ""
              ? undefined
              : yield* Effect.try((): unknown => JSON.parse(text)).pipe(
                  Effect.orElseSucceed(() => undefined)
                );
          if (response.status < 200 || response.status >= 300) {
            const said = (value as { error?: unknown } | undefined)?.error;
            return yield* Effect.fail(
              new CoreError(
                response.status === 403 ? "forbidden" : `http_${response.status}`,
                typeof said === "string"
                  ? said
                  : `The station answered ${response.status}.`,
                response.status
              )
            );
          }
          return value;
        })
      );
    }).pipe(
      Effect.timeoutOrElse({
        duration: STATION_TIMEOUT_MS,
        orElse: () =>
          Effect.fail(new CoreError("timeout", "The station did not answer.")),
      })
    );
  }

  /** A write's key: the station answers a repeat of it as it answered the first. */
  onceKey(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  /**
   * A file the station serves (`GET path`): its bytes, their type, and for a part of a file the whole file's size (its
   * `stillfail-total`). Fails `not_found` when the station has none there, and `too_large` past `max` bytes (what came
   * stops there).
   */
  file(
    workspace: string,
    station: string,
    path: string,
    max: number
  ): Effect.Effect<
    { bytes: Uint8Array; type: string; total: number | null },
    CoreError
  > {
    return Effect.gen({ self: this }, function* () {
      if (!this.#workspaceOf.has(station)) this.#workspaceOf.set(station, workspace);
      const answered = this.#admitted(station, (links) =>
        links.request(station, { method: "GET", path, headers: [], body: null })
      );
      return yield* Effect.scoped(
        Effect.gen(function* () {
          const response = yield* answered;
          if (response.status !== 200)
            return yield* Effect.fail(
              new CoreError(
                response.status === 404 ? "not_found" : `http_${response.status}`,
                `The station answered ${response.status}.`,
                response.status
              )
            );
          const bytes = yield* collect(
            response.body,
            max,
            () => new CoreError("too_large", "The file is larger than the app reads.")
          );
          const total = Number(header(response, "stillfail-total") ?? Number.NaN);
          return {
            bytes,
            type: header(response, "content-type") ?? "",
            total: Number.isSafeInteger(total) && total >= 0 ? total : null,
          };
        })
      );
    }).pipe(
      Effect.timeoutOrElse({
        duration: FILE_TIMEOUT_MS,
        orElse: () =>
          Effect.fail(new CoreError("timeout", "The station did not give the file.")),
      })
    );
  }

  /** A station's event stream (`GET path`): its body as it arrives, open while the scope is. */
  stream(
    workspace: string,
    station: string,
    path: string
  ): Effect.Effect<Pull<Uint8Array>, CoreError, Scope.Scope> {
    return Effect.gen({ self: this }, function* () {
      if (!this.#workspaceOf.has(station)) this.#workspaceOf.set(station, workspace);
      const response = yield* this.#admitted(station, (links) =>
        links.request(station, {
          method: "GET",
          path,
          headers: [["accept", "text/event-stream"]],
          body: null,
        })
      );
      if (response.status !== 200)
        return yield* Effect.fail(
          new CoreError(
            `http_${response.status}`,
            `The station answered ${response.status}.`
          )
        );
      return response.body;
    });
  }

  /** `run` with the signed-in account; fails `signed_out` while there is none. */
  #control<A>(
    run: (account: Account) => Effect.Effect<A, CoreError>
  ): Effect.Effect<A, CoreError> {
    return this.#ctx.session.account().pipe(Effect.flatMap(run));
  }
}

/** A body whole, failing with `tooLarge` past `max` bytes. */
function collect(
  body: Pull<Uint8Array>,
  max: number,
  tooLarge: () => CoreError
): Effect.Effect<Uint8Array, CoreError> {
  return Effect.gen(function* () {
    const parts: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const piece = yield* body.take.pipe(
        Effect.mapError((e) => new CoreError("unreachable", e.message))
      );
      if (piece === null) break;
      size += piece.length;
      if (size > max) return yield* Effect.fail(tooLarge());
      parts.push(piece);
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const part of parts) {
      bytes.set(part, at);
      at += part.length;
    }
    return bytes;
  });
}

function parsed<S extends z.ZodType>(
  schema: S,
  value: unknown
): Effect.Effect<z.output<S>, CoreError> {
  const out = schema.safeParse(value);
  return out.success
    ? Effect.succeed(out.data as z.output<S>)
    : Effect.fail(new CoreError("bad_response", "The station answered unexpectedly."));
}
