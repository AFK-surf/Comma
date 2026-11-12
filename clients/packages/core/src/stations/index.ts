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
// A desktop's own station is in no roster and admits only its owner (systems/station/src/mesh/device-mesh.ts). On a host
// that says `ownComputers` (every app with the mesh), the stations the person's own Devices name are linked as listed ones are,
// and shown apart from them (`ownComputers`): nothing else of the Stations area hears of them.
//
// Bounds: one control-plane read of the account per showing; per shown workspace one list read, one event stream and
// one connection per listed station (the control plane bounds how many a workspace has); one credential request per
// workspace a day (less when the session ends sooner), and one more when a station refuses the credential kept (a
// station that refuses a new one too gets no other until it admits one); per shown workspace with stations one relay
// socket, and a ticket for each socket opened (two a minute while none lasts). With `ownComputers`, one Devices read each
// time the list is read, of at most one page, and a connection for each station it names. The endpoint is bound only while some
// workspace's stations are kept (shown, or always.ts), and closed when the account changes.
//
// The account's database keeps each workspace's stations (`station`) and its credential (`station_cred`, until it
// expires by the core's clock or a station refuses it): after a restart, stations are reached with them before the
// control plane answers, or while it does not.
import { lazySchema } from "@comma/chat-contract";
import {
  CoreError,
  madeOnce,
  type HostError,
  type Scoped,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import {
  Deferred,
  Duration,
  Effect,
  Exit,
  Fiber,
  Result,
  Scope,
  Semaphore,
} from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
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
import {
  header,
  stationLink,
  stationRefused,
  type Pull,
  type StationLinks,
} from "../host.ts";
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
/**
 * An open connection is asked whether its station is still there this often, and given up as silent when no answer
 * came this long after the question: a station whose process was killed says nothing more, and QUIC tells only at its
 * idle timeout. A new connection is then opened beside it (`StationLinks.refresh`), and takes its place unless the old
 * one answered meanwhile (the network only paused). A question that waited much longer than PING_EVERY_MS to be asked
 * (this device slept, or its app was in the background) is not counted: the next one is. One small exchange each 2 s a
 * station connection, of the few stations a person holds open.
 */
const PING_EVERY_MS = 2_000;
const PING_TIMEOUT_MS = 1_500;
/**
 * The most new connections opened at once beside one gone silent. Each unanswered ping opens one more beside those
 * still trying, rather than waiting on them: one dialled before the station is back resends its first packet only
 * after 1 s, then 2 s, so a new one sent meanwhile reaches the station sooner (a restart is back up in about 3 s).
 */
const REFRESHING_AT_MOST = 3;
/**
 * A connection whose station has answered nothing this long, and no new one replaced, is closed: the station is gone
 * (its computer off), and is shown so, as when QUIC gave such a connection up at its own 30 s. Connections may be idle
 * longer (CONNECTION_IDLE_MS in the mesh's native code) for a phone app frozen in the background, which asks nothing
 * meanwhile (a question asked late does not count).
 */
const STATION_GONE_MS = 30_000;
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

const accessSchema = lazySchema(() =>
  z.object({ access: z.enum(["off", "read", "full"]) })
);

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
  /** The stations of the person's own computers, linked with the listed ones (`ownComputers`). */
  ownComputers: readonly string[];
};

type Mesh = {
  scoped: Scoped;
  links: Deferred.Deferred<StationLinks, CoreError>;
};

/** How often the person's own computers are read while shown: one read a workspace. */
const OWN_COMPUTERS_EVERY_MS = 30_000;
const devicesPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/devices`;
/** What `ownComputers` reads of the person's own computers (the server lists no one else's). */
const ownComputersSchema = lazySchema(() =>
  z.object({
    devices: z
      .array(
        z.object({
          station_id: z
            .string()
            .regex(/^[0-9a-f]{64}$/)
            .nullish(),
        })
      )
      .max(50),
  })
);

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

/** A refusal is the station's answer, for what it says; only what did not reach it is another way's to try. */
const linkFailure = (error: HostError) =>
  stationRefused(error)
    ? new CoreError("unauthorized", error.message)
    : new CoreError("unreachable", error.message);

/** A station's link before the device heard from it. */
const CONNECTING: Link = { state: "connecting" };

/** A listed station's row, made once for the same listing and link. */
const stationRow = madeOnce(
  (s: ListedStation, link: Link): StationRow => ({
    id: s.id,
    name: s.name,
    version: s.version,
    present: s.online,
    enrolledAt: s.enrolled_at ?? null,
    enrolledBy: s.enrolled_by ?? null,
    link,
  })
);

const ownComputer = madeOnce((link: Link, id: string) => ({ id, link }));

export class Stations {
  readonly #ctx: Ctx;
  #accountKey: string | null = null;
  #home: { loading: boolean; error: string | undefined } = {
    loading: false,
    error: undefined,
  };
  readonly #shown = new Map<string, Shown>();
  readonly #links = new Map<string, Link>();
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
      ownComputers: [],
    };
    this.#shown.set(workspace, shown);
    if (kept) this.#follow(workspace, kept);
    this.#ctx.runner.fork(
      this.#control((account) =>
        this.#readList(account, workspace).pipe(
          Effect.andThen(
            Effect.all(
              [
                this.#presence(account, workspace),
                this.#keepOwnComputers(account, workspace),
              ],
              { concurrency: "unbounded", discard: true }
            )
          )
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
    for (const id of shown.linked.keys())
      this.#links.delete(stationLink(workspace, id));
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
      online:
        s.online || this.#links.get(stationLink(workspace, s.id))?.state === "online",
    }));
  }

  /** This device's connection to `station`, as it stands. */
  linkOf(station: string): Link {
    for (const [link, state] of this.#links)
      if (link.startsWith(`${station}@`)) return state;
    return { state: "connecting" };
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
      stations: kept.map((s) =>
        stationRow(s, this.#links.get(stationLink(workspace, s.id)) ?? CONNECTING)
      ),
      ...(shown && shown.ownComputers.length > 0
        ? {
            ownComputers: shown.ownComputers.map((id) =>
              ownComputer(this.#links.get(stationLink(workspace, id)) ?? CONNECTING, id)
            ),
          }
        : {}),
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
      Effect.tap(() => this.#readOwnComputers(account, workspace)),
      Effect.asVoid
    );
  }

  /** A computer's station is told the Devices list once it first connected: read again while shown. */
  #keepOwnComputers(account: Account, workspace: string): Effect.Effect<void> {
    if (!this.#ctx.host.stationMesh?.ownComputers) return Effect.void;
    return Effect.forever(
      Effect.sleep(OWN_COMPUTERS_EVERY_MS).pipe(
        Effect.andThen(this.#readOwnComputers(account, workspace))
      )
    );
  }

  /** A view of `station`'s screen is asked for: linked now, with its relay socket, whether or not the list has come. */
  linkOwnComputer(workspace: string, station: string): void {
    const shown = this.#shown.get(workspace);
    const account = this.#ctx.session.current();
    if (!shown || !account || shown.ownComputers.includes(station)) return;
    shown.ownComputers = [...shown.ownComputers, station];
    this.#follow(workspace, account.stationList<ListedStation>(workspace) ?? []);
    this.#changed(workspace);
  }

  /** Links the stations of the person's own computers, where the host says to. A failed read changes nothing. */
  #readOwnComputers(account: Account, workspace: string): Effect.Effect<void> {
    if (!this.#ctx.host.stationMesh?.ownComputers) return Effect.void;
    return this.#ctx.api
      .request(account, "GET", `${devicesPath(workspace)}?limit=50`, ownComputersSchema)
      .pipe(
        Effect.tap(({ devices }) =>
          Effect.sync(() => {
            const shown = this.#shown.get(workspace);
            if (!shown || account.closed) return;
            shown.ownComputers = [
              ...new Set(devices.flatMap((d) => (d.station_id ? [d.station_id] : []))),
            ];
            this.#follow(
              workspace,
              account.stationList<ListedStation>(workspace) ?? []
            );
            this.#changed(workspace);
          })
        ),
        Effect.ignore
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
    const listed = new Set([...stations.map((s) => s.id), ...shown.ownComputers]);
    for (const [id, scoped] of shown.linked) {
      if (listed.has(id)) continue;
      shown.linked.delete(id);
      this.#links.delete(stationLink(workspace, id));
      this.#ctx.runner.close(scoped);
    }
    for (const id of listed) {
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
          ? yield* links
              .nextVia(stationLink(workspace, station), via)
              .pipe(Effect.orElseSucceed(() => null))
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

  /**
   * Asks the station on the open connection whether it is still there, each PING_EVERY_MS (`PING_EVERY_MS`); one that
   * does not answer within PING_TIMEOUT_MS gets a new connection beside it, which takes its place unless an answer came
   * meanwhile; one more is opened beside those still trying at each ping unanswered (REFRESHING_AT_MOST). Runs while
   * the connection is open: never ends by itself.
   */
  #keepAsking(workspace: string, station: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      let asked = this.#ctx.now();
      let heardAt = asked;
      let refreshing = 0;
      for (;;) {
        yield* Effect.sleep(Duration.millis(PING_EVERY_MS));
        const now = this.#ctx.now();
        // (asked much later than meant: this device slept, and its links are no evidence of the station's)
        const late = now - asked > 2 * PING_EVERY_MS;
        asked = now;
        if (late) heardAt = now;
        // The question goes on after its while: an answer that comes late keeps the old connection (`wanted`). Its
        // while counts from when it is written: what comes first (a credential renewed through the control plane, a
        // stream to write it on) is no sign of the station's.
        let answered = false;
        let links: StationLinks | undefined;
        let link = "";
        // Written within a round, or this round is let go: no stream to write it on (the station's are all open) is no
        // sign the station went; what the connection hears meanwhile answers, and nothing at all for STATION_GONE_MS
        // gives it up below.
        const written = yield* Effect.result(
          this.#admitted(workspace, station, (l, k) => {
            links = l;
            link = k;
            return l.ping ? l.ping(k) : Effect.succeed(Effect.succeed(true));
          }).pipe(Effect.timeout(Duration.millis(PING_EVERY_MS)))
        );
        if (Result.isFailure(written)) {
          if (!late && this.#ctx.now() - heardAt >= STATION_GONE_MS) {
            if (links?.drop) yield* links.drop(link);
            return;
          }
          continue;
        }
        const question = yield* written.success.pipe(
          Effect.tap((said) => Effect.sync(() => void (answered = said))),
          Effect.forkChild
        );
        const said = yield* Fiber.join(question).pipe(
          Effect.timeout(Duration.millis(PING_TIMEOUT_MS)),
          Effect.result
        );
        if (Result.isSuccess(said) || late) {
          if (Result.isSuccess(said)) heardAt = this.#ctx.now();
          yield* Fiber.interrupt(question);
          continue;
        }
        if (this.#ctx.now() - heardAt >= STATION_GONE_MS) {
          yield* Fiber.interrupt(question);
          if (links?.drop) yield* links.drop(link);
          return;
        }
        if (refreshing >= REFRESHING_AT_MOST) {
          yield* Fiber.interrupt(question);
          continue;
        }
        refreshing += 1;
        yield* Effect.ignore(this.refresh(workspace, station, () => !answered)).pipe(
          Effect.andThen(Fiber.interrupt(question)),
          Effect.ensuring(Effect.sync(() => void (refreshing -= 1))),
          Effect.forkChild
        );
      }
    });
  }

  #setLink(workspace: string, station: string, link: Link): void {
    const key = stationLink(workspace, station);
    const before = this.#links.get(key);
    if (
      before?.state === link.state &&
      before.message === link.message &&
      before.via === link.via
    )
      return;
    this.#links.set(key, link);
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
          this.#admitted(workspace, station, (links, link) => links.connect(link)).pipe(
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
          // Open until it closes, saying meanwhile how it runs, and asked whether its station is still there.
          yield* Effect.raceFirst(
            opened.success,
            Effect.raceFirst(
              this.#followVia(workspace, station),
              this.#keepAsking(workspace, station)
            )
          );
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
          .open({
            secretKey,
            relays: me.relay_urls,
            ...(me.route_policy ? { routePolicy: me.route_policy } : {}),
          })
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
  #linkTo(
    workspace: string,
    station: string
  ): Effect.Effect<
    {
      links: StationLinks;
      link: string;
      account: Account;
      workspace: string;
      credential: string;
      issued: boolean;
    },
    CoreError
  > {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account();
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
      const link = stationLink(workspace, station);
      links.credential(link, given.credential);
      const listed = account
        .stationList<ListedStation>(workspace)
        ?.find((s) => s.id === station);
      // A computer's station announces nothing and is in no list: it keeps to each of the control plane's relays.
      const own = !listed && this.#shown.get(workspace)?.ownComputers.includes(station);
      links.reach(link, {
        relayUrl:
          listed?.home_relay ??
          (own ? (account.doc<Me>(ME_DOC)?.value.relay_urls[0] ?? null) : null),
        addrs: listed?.addrs ?? [],
      });
      return { links, link, account, workspace, ...given };
    });
  }

  /**
   * `use` of the endpoint, with a member credential given for `station`. A station that refuses a credential this
   * device kept (the control plane changed what it signs since: the workspace's id, its keys) is given a newly issued
   * one and asked once more. A station that refuses a newly issued one is not given another until it has admitted
   * one: each try after that uses what is kept, so a refusing station costs one credential request, not one a try.
   */
  #admitted<A, R>(
    workspace: string,
    station: string,
    use: (links: StationLinks, link: string) => Effect.Effect<A, HostError, R>
  ): Effect.Effect<A, CoreError, R> {
    return Effect.gen({ self: this }, function* () {
      const key = stationLink(workspace, station);
      const first = yield* this.#linkTo(workspace, station);
      const tried = yield* Effect.result(use(first.links, first.link));
      if (Result.isSuccess(tried)) {
        this.#refusing.delete(key);
        return tried.success;
      }
      if (!stationRefused(tried.failure))
        return yield* Effect.fail(linkFailure(tried.failure));
      if (first.issued || this.#refusing.has(key)) {
        this.#refusing.add(key);
        return yield* Effect.fail(linkFailure(tried.failure));
      }
      // The kept one goes, unless another station's refusal already replaced it.
      if (
        first.account.stationCredential<IssuedCredential>(first.workspace)?.value
          .credential === first.credential
      )
        first.account.deleteStationCredential(first.workspace);
      const second = yield* this.#linkTo(workspace, station);
      return yield* use(second.links, second.link).pipe(
        Effect.tap(() => Effect.sync(() => this.#refusing.delete(key))),
        Effect.mapError((e) => {
          if (stationRefused(e)) this.#refusing.add(key);
          return linkFailure(e);
        })
      );
    });
  }

  /**
   * Opens a new connection to `station` beside the open one, which carries nothing though it is still open (the
   * station's process went, and a new one has its key), and puts it in that one's place: what was on the old one fails,
   * to be asked again. `wanted` is asked once the new one opened; false keeps the old one. True when it was replaced.
   */
  refresh(
    workspace: string,
    station: string,
    wanted: () => boolean
  ): Effect.Effect<boolean, CoreError> {
    return this.#admitted(workspace, station, (links, link) =>
      links.refresh ? links.refresh(link, wanted) : Effect.succeed(false)
    );
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
      const headers: [string, string][] = [["accept", "application/json"]];
      if (options.raw) headers.push(["content-type", options.raw.type]);
      else if (body !== undefined) headers.push(["content-type", "application/json"]);
      if (method !== "GET")
        headers.push(["idempotency-key", options.onceKey ?? this.onceKey()]);
      const answered = this.#admitted(workspace, station, (links, link) =>
        links.request(link, {
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
   * `comma-station-total`). Fails `not_found` when the station has none there, and `too_large` past `max` bytes (what came
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
      const answered = this.#admitted(workspace, station, (links, link) =>
        links.request(link, { method: "GET", path, headers: [], body: null })
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
          const total = Number(
            header(response, "comma-station-total") ??
              header(response, "stillfail-total") ??
              Number.NaN
          );
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

  /** A station's event stream (`GET path`): its body as it arrives, open while the scope is, and its headers. */
  stream(
    workspace: string,
    station: string,
    path: string
  ): Effect.Effect<
    { body: Pull<Uint8Array>; headers: [string, string][] },
    CoreError,
    Scope.Scope
  > {
    return Effect.gen({ self: this }, function* () {
      const response = yield* this.#admitted(workspace, station, (links, link) =>
        links.request(link, {
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
      return { body: response.body, headers: response.headers };
    });
  }

  /**
   * A two-way stream with a station (`POST path`): `outgoing` goes as it comes while the body comes back, open while
   * the scope is. A refusal fails with the station's words, its code `http_<status>` (403: `forbidden`).
   */
  duplex(
    workspace: string,
    station: string,
    path: string,
    headers: [string, string][],
    outgoing: AsyncIterable<Uint8Array>
  ): Effect.Effect<
    { body: Pull<Uint8Array>; headers: [string, string][] },
    CoreError,
    Scope.Scope
  > {
    return Effect.gen({ self: this }, function* () {
      const response = yield* this.#admitted(workspace, station, (links, link) =>
        links.request(link, { method: "POST", path, headers, body: outgoing })
      );
      if (response.status === 200)
        return { body: response.body, headers: response.headers };
      const bytes = yield* collect(
        response.body,
        MAX_ANSWER_BYTES,
        () => new CoreError("bad_response", "The station's answer is too large.")
      );
      const said = yield* Effect.try((): unknown =>
        JSON.parse(new TextDecoder().decode(bytes))
      ).pipe(Effect.orElseSucceed(() => undefined));
      const error = (said as { error?: unknown } | undefined)?.error;
      return yield* Effect.fail(
        new CoreError(
          response.status === 403 ? "forbidden" : `http_${response.status}`,
          typeof error === "string"
            ? error
            : `The station answered ${response.status}.`,
          response.status
        )
      );
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
