// Settings › Devices (each visit its own topic, `visit`): the signed-in person's own computers in a workspace (the first
// page of 20, more on request, at most 50 kept; the server leaves out other members' computers and install commands
// never used), the workspace's Cloud VM (read with the first page), this computer
// read by its id wherever it falls in the list, and each one's Agent runtimes. While shown, the first page and this
// computer are read every 15 s; each runtime's readiness says until when it holds, and the core shows it as stale from
// that moment (`fresh`), without a request. On the first read of a visit, a connected computer that allows operations
// and has a stale or expired runtime is checked once (its Connector probes it); a person can check one again.
//
// Bounds: one list read in flight per page shown; probes two at a time, at most 50 queued per visit, each given up after
// 35 s; one timer for the next readiness expiry. Changes are one request each, then one read.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Fiber, Option, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { deviceSchema } from "./comma/schemas.ts";
import { enrollmentSchema } from "./stations/control.ts";
import type {
  Device,
  DeviceEnrollment,
  DevicesValue,
  ScreenStreamIceServer,
  ShownDevice,
} from "./contract.ts";
import type { ChatDeviceSetupOffer } from "@comma/chat-contract";
import { deviceSetupOfferValue } from "./chat/model/inlineElementContract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const POLL_MS = 15_000;
const PAGE = 20;
const KEPT = 50;
const PROBE_TIMEOUT_MS = 35_000;
const AGENTS = new Set(["codex", "claude", "pi", "kimi"]);

const devicesPath = (ws: string) => route`/v1/comma/workspaces/${ws}/devices`;
const devicePath = (ws: string, id: string) =>
  route`/v1/comma/workspaces/${ws}/devices/${id}`;
// A row this client cannot read is left out rather than failing the page, as the server skips a device it cannot project.
const pageSchema = z.object({
  devices: z.array(z.unknown()).transform((rows) =>
    rows.flatMap((row) => {
      const read = deviceSchema.safeParse(row);
      return read.success ? [read.data] : [];
    })
  ),
  cloud_vm: z
    .unknown()
    .optional()
    .transform((row) => {
      const read = deviceSchema.safeParse(row);
      return read.success ? read.data : null;
    }),
  next_cursor: z.string().nullable(),
});

/** What the server answers for a reported device that is, or was, offered: the phone says no more of it. */
const NEARBY_TAKEN = new Set(["offered", "duplicate", "already_connected", "ignored"]);
const nearbySchema = z.object({
  reporter: z.string().min(1).max(256),
  request: z.string().min(1).max(256),
  device: z.object({
    name: z.string().min(1).max(256),
    model: z.string().min(1).max(256),
    state: z.string().max(64),
    shortId: z.string().regex(/^[0-9A-Fa-f]{4}$/),
    rssi: z.number().int(),
  }),
});

const iceServerSchema = z.object({
  urls: z.array(z.string()).min(1).max(8),
  username: z.string().optional(),
  credential: z.string().optional(),
});
const iceServer = (server: z.infer<typeof iceServerSchema>): ScreenStreamIceServer => ({
  urls: server.urls,
  ...(server.username === undefined ? {} : { username: server.username }),
  ...(server.credential === undefined ? {} : { credential: server.credential }),
});

type Shown = {
  workspace: string | null;
  devices: Device[];
  cloud: Device | null;
  cursor: string | null;
  loading: boolean;
  failed: boolean;
  checks: Record<string, "pending" | "failed">;
  /** Whether this visit's first read happened (it starts the automatic checks). */
  observed: boolean;
  observedDevices: Set<string>;
  probing: Set<string>;
  expiry: Fiber.Fiber<unknown, unknown> | null;
  /** Reads go one at a time. */
  reads: Semaphore.Semaphore;
  /** Each change to a row (a check's answer, an access change) counts up; a read started before it keeps that row. */
  version: number;
  patched: Map<string, number>;
};

const params = {
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > 256)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
};

const keyOf = (topic: Topic) =>
  `${topic.prefer ?? ""}\n${topic.local ?? ""}\n${topic.visit ?? ""}`;

export class Devices {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, Shown>();
  readonly #probes = Semaphore.makeUnsafe(2);
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("devices", {
      start: (topic) => {
        this.#shown.set(keyOf(topic), Devices.#empty());
        this.#live.run(topic, this.#keep(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#drop(keyOf(topic));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        this.#drop(keyOf(topic));
        this.#shown.set(keyOf(topic), Devices.#empty());
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#keep(topic));
      }
    });

    kernel.calls({
      "devices.refresh": {
        run: () =>
          Effect.forEach(this.#topics(), (t) => this.#read(t, undefined, true)).pipe(
            Effect.as(null)
          ),
      },
      "devices.more": {
        run: () =>
          Effect.forEach(this.#topics(), (t) => {
            const cursor = this.#shown.get(keyOf(t))?.cursor;
            return cursor ? this.#read(t, cursor, false) : Effect.void;
          }).pipe(Effect.as(null)),
      },
      "devices.check": {
        run: (p) => {
          const device = params.string(p, "device");
          return Effect.sync(() => {
            for (const topic of this.#topics()) this.#check(topic, device);
            return null;
          });
        },
      },
      "devices.setAccess": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const device = params.string(p, "device");
          const access = (p as { access?: unknown } | null)?.access;
          if (access !== "off" && access !== "read" && access !== "full")
            throw CoreError.invalid("access is off, read or full");
          return this.#send(
            "PUT",
            `${devicePath(workspace, device)}/access`,
            z.object({
              access: z.enum(["off", "read", "full"]).optional(),
              allows_operations: z.boolean(),
            }),
            { access }
          ).pipe(
            Effect.map(
              (result): Pick<Device, "access" | "allows_operations"> => ({
                // A server from before answers the permission alone.
                access: result.access ?? (result.allows_operations ? "full" : "read"),
                allows_operations: result.allows_operations,
              })
            ),
            Effect.tap((result) =>
              Effect.sync(() => this.#patch(device, (row) => ({ ...row, ...result })))
            ),
            // The access answer carries the permission alone; readiness is the Connector's to report, so read it now.
            Effect.ensuring(this.#rereadAll()),
            Effect.map((result) => result.access!)
          );
        },
      },
      // The one-hour command that installs a station on another computer and adds it to the workspace as the
      // signed-in member's (any member but a read-only one).
      "devices.enroll": {
        doing: true,
        run: (p) =>
          this.#send(
            "POST",
            route`/v1/comma/workspaces/${params.string(p, "workspace")}/stations/enrollments`,
            enrollmentSchema,
            {}
          ).pipe(
            Effect.map(
              (answer): DeviceEnrollment => ({
                command: answer.command,
                expiresAt: answer.expires_at,
              })
            )
          ),
      },
      "devices.screenStreamIce": {
        run: (p) =>
          this.#send(
            "POST",
            `${devicePath(params.string(p, "workspace"), params.string(p, "device"))}/screen-stream`,
            z.object({ ice_servers: z.array(iceServerSchema).max(4) }),
            { op: "ice" }
          ).pipe(
            Effect.map((answer) => ({ servers: answer.ice_servers.map(iceServer) }))
          ),
      },
      "devices.startScreenStream": {
        run: (p) => {
          const input = p as {
            target?: unknown;
            apps?: unknown;
            control?: unknown;
            background?: unknown;
          } | null;
          const sdp = (p as { sdp?: unknown } | null)?.sdp;
          if (typeof sdp !== "string" || sdp === "" || sdp.length > 65_536)
            throw CoreError.invalid("sdp is required");
          if (input?.target !== "app" && input?.target !== "display")
            throw CoreError.invalid("target is required");
          const apps = Array.isArray(input.apps)
            ? input.apps
                .filter((app): app is string => typeof app === "string")
                .slice(0, 8)
            : [];
          return this.#send(
            "POST",
            `${devicePath(params.string(p, "workspace"), params.string(p, "device"))}/screen-stream`,
            z.object({ sdp: z.string(), stream_id: z.string() }),
            {
              op: "start",
              sdp,
              target: input.target,
              apps,
              control: input.control === true,
              ...(typeof input.background === "string" &&
              /^#[0-9a-f]{6}$/.test(input.background)
                ? { background: input.background }
                : {}),
              ice_servers: z
                .array(iceServerSchema)
                .max(4)
                .catch([])
                .parse((p as { servers?: unknown } | null)?.servers),
            }
          ).pipe(
            Effect.map((answer) => ({ sdp: answer.sdp, stream: answer.stream_id }))
          );
        },
      },
      "devices.stopScreenStream": {
        run: (p) =>
          this.#send(
            "POST",
            `${devicePath(params.string(p, "workspace"), params.string(p, "device"))}/screen-stream`,
            z.object({}),
            { op: "stop", stream_id: params.string(p, "stream") }
          ).pipe(Effect.as(null)),
      },
      "devices.rename": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const device = params.string(p, "device");
          const name = params.string(p, "name").trim();
          return this.#send("PUT", devicePath(workspace, device), deviceSchema, {
            name,
          }).pipe(
            Effect.tap((updated) =>
              Effect.sync(() => this.#patch(device, () => updated))
            ),
            Effect.tap(() => this.#rereadAll()),
            Effect.as(null)
          );
        },
      },
      "devices.remove": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const device = params.string(p, "device");
          return this.#send(
            "DELETE",
            devicePath(workspace, device),
            z.object({ removed: z.boolean() })
          ).pipe(
            Effect.tap(() => Effect.sync(() => this.#patch(device, () => null))),
            Effect.tap(() => this.#rereadAll()),
            Effect.as(null)
          );
        },
      },
      /** One computer read now (null: the workspace has none by that id yet), for a page that waits on it. */
      "devices.get": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const device = params.string(p, "device");
          return this.#ctx.session.account().pipe(
            Effect.flatMap((account) =>
              this.#ctx.api.request(
                account,
                "GET",
                devicePath(workspace, device),
                deviceSchema
              )
            ),
            Effect.map((row): Device | null => row),
            Effect.catchIf(
              (e) => e.status === 404,
              () => Effect.succeed(null)
            )
          );
        },
      },
      /**
       * A Comma device this phone found nearby, told to the workspace: answers whether the server offers to set it up
       * (or already did, or has it connected).
       */
      "devices.reportNearby": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const input = nearbySchema.safeParse(p);
          if (!input.success) throw CoreError.invalid("not a nearby device report");
          const { reporter, request, device } = input.data;
          return this.#send(
            "POST",
            route`/v1/comma/workspaces/${workspace}/nearby-devices`,
            z.object({
              devices: z.array(z.object({ short_id: z.string(), outcome: z.string() })),
            }),
            {
              request_id: request,
              reporter_device_id: reporter,
              devices: [
                {
                  name: device.name,
                  model: device.model,
                  state: device.state,
                  short_id: device.shortId,
                  rssi: device.rssi,
                },
              ],
            }
          ).pipe(
            Effect.map((answer) =>
              answer.devices.some(
                (row) =>
                  row.short_id.toUpperCase() === device.shortId.toUpperCase() &&
                  NEARBY_TAKEN.has(row.outcome)
              )
            )
          );
        },
      },
      /** A device setup offer as the server has it now. */
      "devices.setupOffer": {
        run: (p) =>
          this.#offer("GET", params.string(p, "workspace"), params.string(p, "offer")),
      },
      /**
       * Starts (`started`, with the `device` set up for it once there is one) or dismisses a setup offer; answers the
       * offer. One already moved on (409) answers the offer as it is.
       */
      "devices.actOnSetupOffer": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const offer = params.string(p, "offer");
          const action = (p as { action?: unknown } | null)?.action;
          if (action !== "started" && action !== "dismiss")
            throw CoreError.invalid("action is started or dismiss");
          const device = (p as { device?: unknown } | null)?.device;
          if (device !== undefined && (typeof device !== "string" || device === ""))
            throw CoreError.invalid("device is a string");
          return this.#offer("POST", workspace, offer, {
            action,
            ...(device === undefined ? {} : { device_id: device }),
          }).pipe(
            Effect.catchIf(
              (e) => e.status === 409 && device === undefined,
              () => this.#offer("GET", workspace, offer)
            )
          );
        },
      },
    });
  }

  #offer(
    method: "GET" | "POST",
    workspace: string,
    offer: string,
    body?: unknown
  ): Effect.Effect<ChatDeviceSetupOffer, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          method,
          route`/v1/comma/workspaces/${workspace}/nearby-devices/offers/${offer}`,
          z.object({ offer: z.unknown() }),
          body
        )
      ),
      Effect.flatMap((answer) => {
        const value = deviceSetupOfferValue(answer.offer);
        return value
          ? Effect.succeed(value)
          : Effect.fail(new CoreError("bad_response", "The offer is not one."));
      })
    );
  }

  static #empty(): Shown {
    return {
      workspace: null,
      devices: [],
      cloud: null,
      cursor: null,
      loading: true,
      failed: false,
      checks: {},
      observed: false,
      observedDevices: new Set(),
      probing: new Set(),
      expiry: null,
      reads: Semaphore.makeUnsafe(1),
      version: 0,
      patched: new Map(),
    };
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "devices");
  }

  #drop(key: string): void {
    const shown = this.#shown.get(key);
    if (shown?.expiry) this.#ctx.runner.interrupt(shown.expiry);
    this.#shown.delete(key);
  }

  #changed(key: string): void {
    for (const topic of this.#topics())
      if (keyOf(topic) === key) this.#ctx.kernel.store.invalidate(topic);
  }

  #send<S extends z.ZodType>(
    method: "PUT" | "DELETE" | "POST",
    path: string,
    schema: S,
    body?: unknown
  ) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );
  }

  /** Changes a row on every shown page (null removes it). */
  #patch(device: string, change: (row: Device) => Device | null): void {
    for (const [key, shown] of this.#shown) {
      shown.patched.set(device, ++shown.version);
      shown.devices = shown.devices.flatMap((row) => {
        if (row.device_id !== device) return [row];
        const next = change(row);
        return next ? [next] : [];
      });
      if (shown.cloud?.device_id === device) shown.cloud = change(shown.cloud);
      this.#scheduleExpiry(key);
      this.#changed(key);
    }
  }

  #rereadAll(): Effect.Effect<void> {
    return Effect.forEach(this.#topics(), (t) => this.#read(t, undefined, true)).pipe(
      Effect.asVoid
    );
  }

  /** The first read, then every 15 s. */
  #keep(topic: Topic): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      yield* this.#read(topic, undefined, false);
      for (;;) {
        yield* Effect.sleep(POLL_MS);
        // Within the core's grace after the last UI let it go, nothing is read.
        if (this.#ctx.kernel.store.subscribed(topic))
          yield* this.#read(topic, undefined, true);
      }
    });
  }

  #workspaceOf(account: Account, prefer: string): Effect.Effect<string | null> {
    return Effect.gen({ self: this }, function* () {
      if (!this.#workspaces.list(account)?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account) ?? [];
      return (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
    });
  }

  /**
   * Reads a page and this computer. A refresh (`background`) reads the first page and replaces what it covers, so a
   * computer deleted elsewhere stops being listed; pages asked for beyond the first are offered again, not kept.
   */
  #read(
    topic: Topic,
    after: string | undefined,
    background: boolean
  ): Effect.Effect<void> {
    const key = keyOf(topic);
    const local = String(topic.local ?? "");
    const reads = this.#shown.get(key)?.reads;
    if (!reads) return Effect.void;
    return reads.withPermits(1)(
      Effect.gen({ self: this }, function* () {
        const ctx = this.#ctx;
        const account = yield* ctx.session.account().pipe(Effect.option);
        const shown = this.#shown.get(key);
        if (Option.isNone(account) || !shown) return;
        const workspace = yield* this.#workspaceOf(
          account.value,
          String(topic.prefer ?? "")
        );
        if (!workspace) {
          Object.assign(shown, { loading: false, failed: true });
          this.#changed(key);
          return;
        }
        shown.workspace = workspace;
        if (!background) {
          shown.loading = true;
          this.#changed(key);
        }
        const startedAt = shown.version;
        const query = new URLSearchParams({ limit: String(PAGE) });
        if (after) query.set("cursor", after);
        const readLocal = local
          ? ctx.api
              .request(account.value, "GET", devicePath(workspace, local), deviceSchema)
              .pipe(
                Effect.map((d): Device | null => d),
                Effect.catchIf(
                  (e: CoreError) => e.status === 404,
                  () => Effect.succeed(null)
                )
              )
          : Effect.succeed(null);
        const answer = yield* Effect.all(
          [
            ctx.api.request(
              account.value,
              "GET",
              `${devicesPath(workspace)}?${query}`,
              pageSchema
            ),
            readLocal,
          ],
          { concurrency: "unbounded" }
        ).pipe(Effect.option);
        if (this.#shown.get(key) !== shown) return;
        shown.loading = false;
        if (Option.isNone(answer)) {
          shown.failed = true;
          this.#changed(key);
          return;
        }
        const [page, current] = answer.value;
        const rows = new Map(
          (after ? shown.devices : []).map((row) => [row.device_id, row])
        );
        const known = new Map(shown.devices.map((row) => [row.device_id, row]));
        for (const row of [...page.devices, ...(current ? [current] : [])]) {
          // A row changed after this read started (a check answered) is newer than what the read says.
          const newer = (shown.patched.get(row.device_id) ?? 0) > startedAt;
          if (newer && !known.has(row.device_id)) continue;
          rows.delete(row.device_id);
          rows.set(row.device_id, newer ? known.get(row.device_id)! : row);
        }
        if (local && !current) rows.delete(local);
        shown.devices = [...rows.values()].slice(-KEPT);
        // The first page carries the Cloud VM; a row changed after this read started keeps its change.
        if (!after) {
          const cloud = page.cloud_vm;
          shown.cloud =
            cloud &&
            (shown.patched.get(cloud.device_id) ?? 0) > startedAt &&
            shown.cloud?.device_id === cloud.device_id
              ? shown.cloud
              : cloud;
        }
        shown.cursor = page.next_cursor;
        shown.failed = false;
        this.#scheduleExpiry(key);
        this.#changed(key);
        this.#checkOnEntry(
          topic,
          after || !page.cloud_vm ? page.devices : [...page.devices, page.cloud_vm],
          current
        );
      })
    );
  }

  /**
   * Only the first read of a visit starts automatic checks; this computer is looked at once too. A list read without a
   * visit (another page choosing a computer) checks nothing.
   */
  #checkOnEntry(
    topic: Topic,
    devices: readonly Device[],
    current: Device | null
  ): void {
    if (!topic.visit) return;
    const shown = this.#shown.get(keyOf(topic));
    if (!shown) return;
    const initial = shown.observed ? [] : devices.slice(0, KEPT);
    shown.observed = true;
    if (current) initial.push(current);
    const now = this.#ctx.now() / 1000;
    for (const device of initial) {
      if (shown.observedDevices.has(device.device_id)) continue;
      shown.observedDevices.add(device.device_id);
      if (
        device.status === "connected" &&
        device.allows_operations &&
        device.device_runtimes.some(
          (runtime) =>
            AGENTS.has(runtime.provider) &&
            (runtime.status === "stale" ||
              (runtime.readiness_valid_until != null &&
                runtime.readiness_valid_until <= now) ||
              (runtime.status === "ready" && !runtime.readiness_valid_until))
        )
      )
        this.#check(topic, device.device_id);
    }
  }

  /** Asks a computer's Connector to probe its runtimes: two at a time, at most 50 per visit. */
  #check(topic: Topic, device: string): void {
    const key = keyOf(topic);
    const shown = this.#shown.get(key);
    if (!shown?.workspace || shown.probing.has(device) || shown.probing.size >= KEPT)
      return;
    const workspace = shown.workspace;
    shown.probing.add(device);
    shown.checks = { ...shown.checks, [device]: "pending" };
    this.#changed(key);
    const ctx = this.#ctx;
    this.#live.run(
      topic,
      this.#probes.withPermits(1)(
        ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "POST",
              `${devicePath(workspace, device)}/probe`,
              deviceSchema,
              {},
              PROBE_TIMEOUT_MS
            )
          ),
          Effect.tap((probed) => Effect.sync(() => this.#patch(device, () => probed))),
          Effect.as(true),
          Effect.orElseSucceed(() => false),
          Effect.tap((ok) =>
            Effect.sync(() => {
              if (this.#shown.get(key) !== shown) return;
              shown.probing.delete(device);
              const { [device]: _, ...rest } = shown.checks;
              shown.checks = ok ? rest : { ...rest, [device]: "failed" };
              this.#changed(key);
            })
          )
        )
      )
    );
  }

  /** One timer for the next readiness expiry of what is shown: at that moment it is shown as stale. */
  #scheduleExpiry(key: string): void {
    const shown = this.#shown.get(key);
    if (!shown) return;
    if (shown.expiry) this.#ctx.runner.interrupt(shown.expiry);
    shown.expiry = null;
    const now = this.#ctx.now();
    const next = Math.min(
      ...[...shown.devices, ...(shown.cloud ? [shown.cloud] : [])]
        .flatMap((d) =>
          d.device_runtimes.map((r) => (r.readiness_valid_until ?? 0) * 1000)
        )
        .filter((at) => at > now)
    );
    if (!Number.isFinite(next)) return;
    shown.expiry = this.#ctx.runner.fork(
      Effect.sleep(next - now).pipe(
        Effect.andThen(
          Effect.sync(() => {
            if (this.#shown.get(key) !== shown) return;
            shown.expiry = null;
            this.#changed(key);
            this.#scheduleExpiry(key);
          })
        )
      )
    );
  }

  #value(topic: Topic): DevicesValue {
    const shown = this.#shown.get(keyOf(topic));
    const now = this.#ctx.now();
    const show = (device: Device): ShownDevice => ({
      ...device,
      device_runtimes: device.device_runtimes.map((runtime) => ({
        ...runtime,
        fresh:
          !!runtime.readiness_valid_until && runtime.readiness_valid_until * 1000 > now,
      })),
    });
    return {
      workspace: shown?.workspace ?? null,
      devices: (shown?.devices ?? []).map(show),
      cloud: shown?.cloud ? show(shown.cloud) : null,
      hasMore: !!shown?.cursor,
      loading: shown?.loading ?? true,
      failed: shown?.failed ?? false,
      checks: shown?.checks ?? {},
    };
  }
}
