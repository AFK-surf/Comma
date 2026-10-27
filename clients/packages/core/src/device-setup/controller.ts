import { CoreError, type Scoped } from "@comma/core-kernel";
import { Effect, Option, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import { deviceSchema } from "../comma/schemas.ts";
import type { registerConnectorCredentials } from "../connector-credentials.ts";
import type { Ctx } from "../ctx.ts";
import {
  SetupFlow,
  timeouts,
  type SetupEffect,
  type SetupEvent,
  type SetupState,
} from "./flow.ts";
import {
  advertisement,
  credentialsJson,
  gatt,
  infoSchema,
  statusSchema,
  WifiPages,
  wifiJson,
  type Credentials,
} from "./protocol.ts";

const inputSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("pick"), id: z.string().min(1).max(256) }),
  z.object({ type: z.literal("rename"), name: z.string().max(200) }),
  z.object({
    type: z.literal("join"),
    ssid: z.string().max(32),
    password: z.string().max(64),
  }),
  ...(["cancel", "retry", "rescan"] as const).map((type) =>
    z.object({ type: z.literal(type) })
  ),
]);
export type SetupInput = z.infer<typeof inputSchema>;
export interface SetupValue {
  supported: boolean;
  bluetooth: string;
  state: SetupState;
}
const recordSchema = z.object({
  deviceId: z.string(),
  connectorToken: z.string(),
  voiceKeyId: z.string(),
  name: z.string(),
  createdAt: z.number(),
  confirmed: z.boolean(),
  revoking: z.boolean().optional(),
});
type Kept = z.infer<typeof recordSchema>;
type Owner = { account: Account; workspace: string };
type Session = Owner & {
  id: string;
  flow: SetupFlow;
  work: Scoped;
  watch: Scoped | null;
  events: Scoped | null;
  pages: WifiPages;
};
const path = (workspace: string, device: string) =>
  route`/v1/comma/workspaces/${workspace}/devices/${device}`;

/** One setup per app. Only its projection is public. Native records are indexed by audience, account and workspace. */
export class DeviceSetup {
  private session: Session | null = null;
  private bluetooth = "pending";
  private next = 0;
  private readonly records = Semaphore.makeUnsafe(1);
  private readonly reconcileWork = new Set<string>();
  constructor(
    private readonly ctx: Ctx,
    private readonly credentials: ReturnType<typeof registerConnectorCredentials>
  ) {
    ctx.kernel.source("deviceSetup", {
      start: () => {},
      stop: () => {},
      compute: () => ({
        ok: {
          supported: !!ctx.host.deviceSetup,
          bluetooth: this.bluetooth,
          state: this.session?.flow.state ?? { step: "idle" },
        } satisfies SetupValue,
      }),
    });
    ctx.session.onChange(() => {
      const s = this.session;
      if (s && s.account.lease !== ctx.session.lease())
        this.send(s, { type: "cancel" });
    });
    ctx.kernel.calls({
      "deviceSetup.start": {
        run: (p) =>
          Effect.gen({ self: this }, function* () {
            const workspace = z
              .object({ workspace: z.string().min(1).max(160) })
              .parse(p).workspace;
            if (!ctx.host.deviceSetup)
              return yield* Effect.fail(
                new CoreError("unsupported", "Bluetooth setup is unavailable")
              );
            const account = yield* ctx.session.account();
            if (this.session) {
              this.send(this.session, { type: "cancel" });
              ctx.runner.close(this.session.work);
            }
            const s: Session = {
              account,
              workspace,
              id: String(++this.next),
              flow: new SetupFlow(),
              work: ctx.runner.child(),
              watch: null,
              events: null,
              pages: new WifiPages(),
            };
            this.session = s;
            this.execute(s, s.flow.start());
            return null;
          }),
      },
      "deviceSetup.event": {
        run: (p) =>
          Effect.sync(() => {
            const input = inputSchema.parse(p);
            if (this.session) this.send(this.session, input);
            return null;
          }),
      },
      "deviceSetup.remove": {
        run: (p) =>
          Effect.gen({ self: this }, function* () {
            const input = z
              .object({
                workspace: z.string().min(1).max(160),
                device: z.string().min(1).max(160),
              })
              .parse(p);
            const account = yield* ctx.session.account();
            const owner = { account, workspace: input.workspace };
            const record = ctx.host.deviceSetup
              ? yield* this.native(owner, "records", { deviceId: input.device }).pipe(
                  Effect.map((v) => z.array(recordSchema).parse(v)[0])
                )
              : undefined;
            yield* this.credentials.unprovision({
              workspaceId: input.workspace,
              deviceId: input.device,
              connectorToken: record?.connectorToken,
              voiceKeyId: record?.voiceKeyId,
              lease: account.lease,
            });
            yield* ctx.api.request(
              account,
              "DELETE",
              path(input.workspace, input.device),
              z.unknown()
            );
            if (ctx.host.deviceSetup)
              yield* this.native(owner, "remove", { deviceId: input.device });
            return null;
          }),
      },
    });
  }
  private native(
    owner: Owner,
    op: Parameters<NonNullable<Ctx["host"]["deviceSetup"]>["call"]>[0],
    input: Record<string, unknown> = {}
  ): Effect.Effect<unknown, CoreError> {
    const port = this.ctx.host.deviceSetup;
    if (!port)
      return Effect.fail(
        new CoreError("unsupported", "Bluetooth setup is unavailable")
      );
    return port
      .call(op, {
        ...input,
        audience: owner.account.lease.audience,
        account: owner.account.userId,
        workspace: owner.workspace,
        lease: owner.account.lease,
      })
      .pipe(
        Effect.mapError(() => new CoreError("native", "Device setup operation failed"))
      );
  }
  private changed(): void {
    this.ctx.kernel.store.invalidate({ topic: "deviceSetup" });
  }
  private send(s: Session, event: SetupEvent): void {
    this.execute(s, s.flow.handle(event));
  }
  private execute(s: Session, effects: SetupEffect[]): void {
    this.changed();
    for (const e of effects) this.effect(s, e);
  }
  private effect(s: Session, e: SetupEffect): void {
    const native = (
      op: Parameters<DeviceSetup["native"]>[1],
      input: Record<string, unknown> = {}
    ) => this.native(s, op, { session: s.id, ...input });
    const run = <A, E>(
      work: Effect.Effect<A, E>,
      success?: (a: A) => void,
      problem = "disconnected",
      root = false,
      attempt?: number
    ) => {
      this.ctx.runner.fork(
        work.pipe(
          Effect.tap((a) => Effect.sync(() => success?.(a))),
          Effect.catch(() =>
            Effect.sync(() =>
              this.send(s, {
                type: "failed",
                problem,
                ...(attempt === undefined ? {} : { attempt }),
              })
            )
          )
        ),
        root ? this.ctx.runner.root : s.work
      );
    };
    switch (e.type) {
      case "scan":
        if (s.events) this.ctx.runner.close(s.events);
        s.events = this.ctx.runner.child(s.work);
        run(
          native("start"),
          () => {
            this.ctx.runner.fork(
              Effect.gen({ self: this }, function* () {
                while (this.session === s && s.flow.state.step !== "cancelled") {
                  const raw = yield* native("next");
                  this.notification(s, raw);
                }
              }).pipe(
                Effect.catch(() => Effect.sync(() => this.send(s, { type: "lost" })))
              ),
              s.events!
            );
          },
          "bluetooth"
        );
        break;
      case "stopScan":
        run(native("stopScan"));
        break;
      case "connect":
        run(
          native("connect", { peripheral: e.device.id }),
          () => this.send(s, { type: "connected" }),
          "connect_failed"
        );
        break;
      case "pair":
        run(
          Effect.gen(function* () {
            const value = yield* native("read", { characteristic: gatt.info });
            const info = infoSchema.parse(JSON.parse(String(value)));
            yield* native("notify", { characteristic: gatt.status });
            yield* native("notify", { characteristic: gatt.wifiScan });
            return info;
          }),
          (info) => this.send(s, { type: "paired", name: info.name }),
          "pairing_failed"
        );
        break;
      case "scanWifi":
        s.pages.reset();
        run(
          native("write", { characteristic: gatt.wifiScan, value: "{}" }),
          undefined,
          "scan_failed"
        );
        break;
      case "join":
        run(
          native("write", {
            characteristic: gatt.wifiCredentials,
            value: wifiJson(e.network, e.password),
          })
        );
        break;
      case "mint":
        // This task survives cancellation so late credentials always reach the flow's revocation path.
        run(
          this.credentials.provision({
            workspaceId: s.workspace,
            name: e.name,
            lease: s.account.lease,
          }),
          (credentials) =>
            this.send(s, { type: "minted", credentials, attempt: e.attempt }),
          "server",
          true,
          e.attempt
        );
        break;
      case "remember":
        run(
          this.put(s, {
            deviceId: e.credentials.deviceId,
            connectorToken: e.credentials.connectorToken,
            voiceKeyId: e.credentials.voiceKeyId,
            name: e.name,
            createdAt: this.ctx.now(),
            confirmed: false,
          }),
          () => this.send(s, { type: "remembered", attempt: e.attempt }),
          "storage",
          true,
          e.attempt
        );
        break;
      case "write":
        run(
          Effect.try({
            try: () => credentialsJson(e.credentials, s.workspace, e.name),
            catch: () => new CoreError("invalid", "Invalid device credentials"),
          }).pipe(
            Effect.flatMap((value) =>
              native("write", { characteristic: gatt.credentials, value })
            )
          ),
          undefined,
          "rejected"
        );
        break;
      case "revoke":
        this.ctx.runner.fork(this.revoke(s, e.credentials).pipe(Effect.ignore));
        break;
      case "confirm":
        run(
          this.native(s, "records", { deviceId: e.deviceId }).pipe(
            Effect.flatMap((v) => {
              const record = z.array(recordSchema).parse(v)[0];
              return record ? this.put(s, { ...record, confirmed: true }) : Effect.void;
            })
          ),
          undefined,
          "storage",
          true
        );
        break;
      case "watch": {
        if (s.watch) this.ctx.runner.close(s.watch);
        const watch = this.ctx.runner.child(s.work);
        s.watch = watch;
        // One device, one request at a time, every two seconds, for at most 90 seconds.
        this.ctx.runner.fork(
          Effect.gen({ self: this }, function* () {
            for (let n = 0; n < 45; n++) {
              const device = yield* this.ctx.api
                .request(s.account, "GET", path(s.workspace, e.deviceId), deviceSchema)
                .pipe(Effect.option);
              if (Option.isSome(device) && device.value.status === "connected") {
                this.send(s, { type: "online" });
                return;
              }
              yield* Effect.sleep(2_000);
            }
          }),
          watch
        );
        break;
      }
      case "stopWatching":
        if (s.watch) this.ctx.runner.close(s.watch);
        s.watch = null;
        break;
      case "disconnect":
        if (s.events) this.ctx.runner.close(s.events);
        s.events = null;
        run(native("disconnect"));
        break;
      case "rename":
        run(
          this.ctx.api.request(
            s.account,
            "PUT",
            path(s.workspace, e.deviceId),
            deviceSchema,
            { name: e.name }
          ),
          undefined,
          "server",
          true
        );
        break;
      case "arm":
        run(Effect.sleep(timeouts[e.timer]), () =>
          this.send(s, { type: "timeout", timer: e.timer, generation: e.generation })
        );
        break;
    }
  }
  private notification(s: Session, raw: unknown): void {
    const event = z
      .object({
        type: z.string(),
        state: z.string().optional(),
        peripheral: z.string().optional(),
        name: z.string().optional(),
        rssi: z.number().optional(),
        manufacturer: z.array(z.number().int().min(0).max(255)).optional(),
        characteristic: z.string().optional(),
        value: z.string().optional(),
      })
      .safeParse(raw);
    if (!event.success) return;
    const e = event.data;
    if (e.type === "state") {
      this.bluetooth = e.state ?? "pending";
      this.changed();
    }
    if (e.type === "found" && e.peripheral) {
      const advert = advertisement(e.manufacturer ?? []);
      if (advert || e.name?.startsWith("Comma-"))
        this.send(s, {
          type: "found",
          device: {
            id: e.peripheral,
            name: advert?.name ?? e.name!,
            rssi: e.rssi ?? -100,
          },
        });
    }
    if (e.type === "lost") this.send(s, { type: "lost" });
    if (e.type !== "value" || !e.value || e.value.length > 4096) return;
    let value: unknown;
    try {
      value = JSON.parse(e.value);
    } catch {
      return;
    }
    if (e.characteristic === gatt.status) {
      const status = statusSchema.safeParse(value);
      if (status.success) this.send(s, { type: "status", status: status.data });
    }
    if (e.characteristic === gatt.wifiScan) {
      const networks = s.pages.accept(value);
      if (networks === "failed") this.send(s, { type: "scanFailed" });
      else if (networks) this.send(s, { type: "networks", networks });
    }
  }
  private put(owner: Owner, record: Kept) {
    return this.records.withPermits(1)(this.native(owner, "put", { record }));
  }
  private revoke(
    owner: Owner,
    c: Pick<Credentials, "deviceId" | "connectorToken" | "voiceKeyId">
  ) {
    return this.records.withPermits(1)(
      Effect.gen({ self: this }, function* () {
        // Keep a retry record even for credentials that arrived after cancellation.
        yield* this.native(owner, "put", {
          record: {
            ...c,
            name: c.deviceId,
            createdAt: 0,
            confirmed: false,
            revoking: true,
          },
        }).pipe(Effect.ignore);
        yield* this.credentials.unprovision({
          ...c,
          workspaceId: owner.workspace,
          lease: owner.account.lease,
        });
        yield* this.native(owner, "remove", { deviceId: c.deviceId });
      })
    );
  }
  /** One bounded page per list read. Native storage maintains the pending index, including its cursor. */
  reconcile(account: Account, workspace: string): void {
    if (!this.ctx.host.deviceSetup) return;
    const key = `${account.userId}/${workspace}`;
    if (this.reconcileWork.has(key)) return;
    this.reconcileWork.add(key);
    const owner = { account, workspace };
    this.ctx.runner.fork(
      Effect.gen({ self: this }, function* () {
        const pending = z
          .array(recordSchema)
          .max(20)
          .parse(yield* this.native(owner, "records", { pending: true, limit: 20 }));
        for (const record of pending) {
          if (record.revoking) {
            yield* this.revoke(owner, record);
            continue;
          }
          if (
            this.session?.flow.state.step === "setup" &&
            this.session.workspace === workspace
          )
            continue;
          const device = yield* this.ctx.api
            .request(account, "GET", path(workspace, record.deviceId), deviceSchema)
            .pipe(
              Effect.asSome,
              Effect.catchIf(
                (e) => e.status === 404,
                () => Effect.succeedNone
              )
            );
          if (
            Option.isSome(device) &&
            (device.value.status === "connected" || device.value.system_info)
          )
            yield* this.put(owner, { ...record, confirmed: true });
          else if (this.ctx.now() - record.createdAt > 900_000)
            yield* this.revoke(owner, record);
        }
      }).pipe(
        Effect.ignore,
        Effect.ensuring(Effect.sync(() => this.reconcileWork.delete(key)))
      )
    );
  }
}
