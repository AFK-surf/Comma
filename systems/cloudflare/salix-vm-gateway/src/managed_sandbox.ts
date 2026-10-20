import { Sandbox as SDKSandbox } from "@cloudflare/sandbox";
import { ContainerControl, ControlError, type ControlPermit, type ControlState } from "./control";
import { errorJson } from "./json";


/**
 * What a Container starts with: what its station connects to Salix with (its server and its Workload's connect
 * credential) and, on a wake, the archive its disk is to be, which the image's entrypoint unpacks before it starts the
 * station (and exits when it cannot: a Container never runs a station without its disk).
 */
export type StationEnv = { SALIX_SERVER: string; SALIX_WORKLOAD_CREDENTIAL: string; SALIX_RESTORE_ARCHIVE?: string };


/**
 * How a Container last stopped, as its monitor said: its exit code when it gave one, the monitor's error otherwise.
 * `requested` when a destroy Salix commanded was under way; anything else stopped by itself or was stopped by Cloudflare.
 */
export type ContainerStop = {
  at: number;
  exit_code: number | null;
  error: string | null;
  requested: boolean;
  operation_id: string | null;
  /** When this object issued the start of the Container that stopped; null when another object did (this one was made after it). */
  started_at: number | null;
  /** Who said it stopped: this object's monitor of the Container it started, or the SDK for one it found. */
  seen_by: "monitor" | "sdk";
};

export type ControlObservation = {
  running: boolean;
  control: ControlState | null;
  last_stop: ContainerStop | null;
  // The last stop nobody commanded, kept apart: the destroy that follows it does not replace it.
  last_uncommanded_stop: ContainerStop | null;
  // This covers commands admitted by this protocol, never pre-protocol calls.
  managed_commands_settled: boolean;
};

export class ManagedSandbox<Env = unknown> extends SDKSandbox<Env> {
  #control: ContainerControl;
  #watching = false;
  #startedAt: number | null = null;
  #destroying = false;

  constructor(ctx: DurableObjectState<{}>, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS salix_container_stop (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), value TEXT NOT NULL)");
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS salix_container_uncommanded_stop (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), value TEXT NOT NULL)");
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS salix_container_control (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), value TEXT NOT NULL)");
    this.#control = new ContainerControl({
      read: () => {
        const rows = ctx.storage.sql.exec<{ value: string }>("SELECT value FROM salix_container_control WHERE singleton = 1").toArray();
        return rows.length ? JSON.parse(rows[0].value) as ControlState : undefined;
      },
      write: (state) => { ctx.storage.sql.exec("INSERT INTO salix_container_control(singleton, value) VALUES (1, ?) ON CONFLICT(singleton) DO UPDATE SET value = excluded.value", JSON.stringify(state)); },
      sync: () => ctx.storage.sync(),
    });
  }

  salixObserve(): ControlObservation {
    const control = this.#control.observe() ?? null;
    return {
      running: this.ctx.container?.running === true,
      control,
      last_stop: this.#lastStop("salix_container_stop"),
      last_uncommanded_stop: this.#lastStop("salix_container_uncommanded_stop"),
      managed_commands_settled: control?.sealed === true && control.pending === null,
    };
  }

  async salixOpen(permit: ControlPermit): Promise<ControlObservation> {
    await this.#control.open(permit);
    return this.salixObserve();
  }

  async salixSeal(permit: ControlPermit): Promise<ControlObservation> {
    await this.#control.seal(permit);
    return this.salixObserve();
  }

  // The Container's station connects out to Salix with the credential in `station`; nothing here waits for it. The
  // one native start is the command: once issued it has no retry behind it, so issuing it completes the command.
  // What `station` names to restore belongs to this start alone: a Container found running keeps the disk it has.
  async salixEnsure(permit: ControlPermit, keepAlive: boolean, station: StationEnv): Promise<ControlObservation> {
    await this.#control.run(permit, "ensure", async () => {
      await super.setKeepAlive(keepAlive);
      const container = this.#container();
      // Cloudflare stops a Container shortly after its Durable Object becomes inactive. The SDK's alarm keeps this
      // one active while the Container runs, and only its own start arms it: the alarm a new object sets finds no
      // Container and ends. Armed here for the start below, and for a Container found running without it.
      await this.scheduleNextAlarm();
      // No SDK auto-start loop: the durable permit check and native start have
      // no await between them. An older DO must touch storage before this call.
      this.#control.current(permit, false);
      if (!container.running) {
        container.start({ enableInternet: this.enableInternet, env: { ...this.envVars, ...station }, ...this.entrypoint && { entrypoint: this.entrypoint } });
        this.#startedAt = Date.now();
        this.#watch(container);
      }
    }, () => ({}));
    return this.salixObserve();
  }

  async salixKeepAlive(permit: ControlPermit, enabled: boolean): Promise<void> {
    await this.#control.run(permit, "keepalive", () => super.setKeepAlive(enabled), () => ({}),
      { sealed: this.#control.current(permit).sealed });
  }

  async salixDestroy(permit: ControlPermit, discard = false): Promise<ControlObservation> {
    // Salix authorizes exact local-disk disposal. The seal fences old carrier
    // commands without asserting a terminal result for business input.
    await this.#control.run(permit, "destroy", async () => {
      this.#destroying = true;
      try {
        await this.#container().destroy();
      } finally {
        this.#destroying = false;
      }
      if (this.#container().running) throw new ControlError("container_destroy_unsettled", 503);
    }, () => ({}), { sealed: true, discard });
    return this.salixObserve();
  }

  // Nothing reaches the Container through the gateway: its station connects out.
  override async fetch(): Promise<Response> {
    return errorJson("control_permit_required", 409);
  }

  // The Container this object started: why it stops is kept and logged, so a stop nobody commanded can be told from
  // one Salix asked for. Cloudflare gives no more than the monitor's word; the Container's output is not readable here.
  #watch(container: Container): void {
    if (this.#watching) return;
    this.#watching = true;
    const requested = () => this.#destroying;
    void container.monitor().then(
      () => this.#stopped({ exit_code: 0, error: null }, requested(), "monitor"),
      (error: unknown) => {
        const message = error instanceof Error ? error.message : String(error);
        const code = /(?:exit code|signalled)[^0-9-]*(-?\d+)/i.exec(message);
        this.#stopped({ exit_code: code ? Number(code[1]) : null, error: message.slice(0, 500) }, requested(), "monitor");
      },
    );
  }

  // A stop nobody commanded is also kept apart from the last stop: what follows it is Salix's seal and destroy, and
  // that commanded stop must not be all that is left to read.
  #stopped(how: { exit_code: number | null; error: string | null }, requested: boolean, seenBy: ContainerStop["seen_by"]): void {
    this.#watching = false;
    const stop: ContainerStop = { at: Date.now(), ...how, requested, operation_id: this.#control.observe()?.operation_id ?? null, started_at: this.#startedAt, seen_by: seenBy };
    this.#startedAt = null;
    try {
      for (const table of requested ? ["salix_container_stop"] : ["salix_container_stop", "salix_container_uncommanded_stop"]) {
        this.ctx.storage.sql.exec(`INSERT INTO ${table}(singleton, value) VALUES (1, ?) ON CONFLICT(singleton) DO UPDATE SET value = excluded.value`, JSON.stringify(stop));
      }
      console.log(JSON.stringify({ event: "sandbox_stopped", owner_id: this.#control.observe()?.owner_id ?? null, ...stop }));
    } catch { /* diagnostics cannot change the Container's state */ }
  }

  #lastStop(table: "salix_container_stop" | "salix_container_uncommanded_stop"): ContainerStop | null {
    const rows = this.ctx.storage.sql.exec<{ value: string }>(`SELECT value FROM ${table} WHERE singleton = 1`).toArray();
    return rows.length ? JSON.parse(rows[0].value) as ContainerStop : null;
  }

  // A Container found running by a new object (after a Worker deploy) is watched by the SDK, which says its stop here.
  override async onStop(params?: { exitCode?: number; reason?: string }): Promise<void> {
    if (!this.#watching) this.#stopped({ exit_code: params?.exitCode ?? null, error: params?.reason ?? null }, this.#destroying, "sdk");
    await super.onStop();
  }

  override onError(error: unknown): void {
    if (!this.#watching) this.#stopped({ exit_code: null, error: (error instanceof Error ? error.message : String(error)).slice(0, 500) }, this.#destroying, "sdk");
  }

  #container(): Container {
    const container = this.ctx.container;
    if (!container) throw new ControlError("container_unavailable", 503);
    return container;
  }

  // Old Workers use these SDK methods (getSandbox also asynchronously calls
  // configure). Explicit failure is required: fallback would reopen a seal.
  override async containerFetch(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async start(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async startAndWaitForPorts(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async stop(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async destroy(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async configure(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async setKeepAlive(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async createBackup(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async restoreBackup(): Promise<never> { throw new ControlError("control_permit_required"); }
  override async onStart(): Promise<void> {}
  // The owner explicitly stops/rebuilds managed VMs. An SDK timer has no
  // authority to discard independent runtime work after manager loss.
  override async onActivityExpired(): Promise<void> {}
}
