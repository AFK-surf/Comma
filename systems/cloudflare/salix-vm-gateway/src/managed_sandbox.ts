import { Sandbox as SDKSandbox } from "@cloudflare/sandbox";
import { ContainerControl, ControlError, requestControlPermit, type ControlPermit, type ControlState, type ControlAction } from "./control";
import { errorJson } from "./json";

const PORT = 8080;
const OBSERVATION_TIMEOUT_MS = 20_000;

export type ControlObservation = {
  running: boolean;
  control: ControlState | null;
  // This covers commands admitted by this protocol, never pre-protocol calls.
  managed_commands_settled: boolean;
};

export class ManagedSandbox<Env = unknown> extends SDKSandbox<Env> {
  #control: ContainerControl;

  constructor(ctx: DurableObjectState<{}>, env: Env) {
    super(ctx, env);
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

  async salixEnsure(permit: ControlPermit, keepAlive: boolean): Promise<Response> {
    return this.#control.run(permit, "ensure", async () => {
      await super.setKeepAlive(keepAlive);
      const container = this.#container();
      // No SDK auto-start loop: the durable permit check and native start have
      // no await between them. An older DO must touch storage before this call.
      this.#control.current(permit, false);
      if (!container.running) container.start({ enableInternet: this.enableInternet, env: this.envVars, ...this.entrypoint && { entrypoint: this.entrypoint } });
      this.#control.startIssued(permit);
      const monitored = container.monitor().then(
        () => this.#control.confirmStartEnded(permit),
        (error: unknown) => {
          const exitCode = error && typeof error === "object" && "exitCode" in error ? error.exitCode : undefined;
          const capacity = error instanceof Error && /^there is no container instance that can be provided to this durable object(?:, try again later)?$/i.test(error.message);
          if (Number.isInteger(exitCode) || capacity) return this.#control.confirmStartEnded(permit);
        },
      );
      this.ctx.waitUntil(monitored);
      const response = await this.#readRunning(permit, new Request("http://localhost:8080/readyz"));
      if (!response.ok) throw new ControlError("container_start_unsettled", 503);
      return response;
    }, (response) => ({ status: response.status }));
  }

  async salixStatus(permit: ControlPermit): Promise<Response> {
    const response = await this.#readRunning(permit, new Request("http://localhost:8080/readyz"));
    if (response.ok) await this.#control.confirmReady(permit);
    return response;
  }

  async salixReceipt(permit: ControlPermit, operation: string): Promise<Response> {
    if (!operation || operation.length > 128 || /[\x00-\x1f\x7f]/.test(operation)) throw new ControlError("invalid_archive_operation", 400);
    const response = await this.#readRunning(permit, new Request("http://localhost:8080/archive", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ action: "status", operation }),
    }));
    if (response.ok) {
      const receipt = await response.clone().json().catch(() => null) as Record<string, unknown> | null;
      if (receipt?.operation === operation && receipt.phase === "restored" &&
          Number.isSafeInteger(receipt.next_offset) && Number(receipt.next_offset) > 0 &&
          Number.isSafeInteger(receipt.sessions) && Number(receipt.sessions) >= 0) {
        await this.#control.confirmImported(permit, operation);
      }
    }
    return response;
  }

  async salixForward(permit: ControlPermit, request: Request, action: ControlAction | "observe", archiveOperation?: string): Promise<Response> {
    if (action === "observe") return this.#fetchRunning(permit, request);
    let sealed = false;
    if (action === "connector_control") {
      const body = await request.clone().json() as { action?: unknown; control?: Partial<ControlPermit> };
      if (body.action !== "open" && body.action !== "seal") throw new ControlError("invalid_control_action", 400);
      if (!body.control || (["owner_id", "operation_id", "generation", "revision"] as const).some((key) => body.control?.[key] !== permit[key])) throw new ControlError("invalid_control_permit", 400);
      sealed = body.action === "seal";
    } else if (action === "export") {
      sealed = this.#control.current(permit).sealed;
    } else if (action !== "import") throw new ControlError("invalid_control_action", 400);
    if (action === "connector_control") {
      request = new Request(request, { signal: AbortSignal.timeout(100_000) });
    }
    return this.#control.run(permit, action, () => this.#fetchRunning(permit, request),
      (response) => ({ status: response.status }), { sealed, archive_operation: archiveOperation });
  }

  async salixKeepAlive(permit: ControlPermit, enabled: boolean): Promise<void> {
    await this.#control.run(permit, "keepalive", () => super.setKeepAlive(enabled), () => ({}),
      { sealed: this.#control.current(permit).sealed });
  }

  async salixDestroy(permit: ControlPermit): Promise<ControlObservation> {
    // Salix grants this command only after preserving critical facts. DO seal
    // closes carrier admission; it is not itself data-disposal authorization.
    await this.#control.run(permit, "destroy", async () => {
      await this.#container().destroy();
      if (this.#container().running) throw new ControlError("container_destroy_unsettled", 503);
    }, () => ({}), { sealed: true });
    return this.salixObserve();
  }

  override async fetch(request: Request): Promise<Response> {
    try {
      if (new URL(request.url).pathname !== "/connect" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        throw new ControlError("control_permit_required");
      }
      const permit = requestControlPermit(request);
      const url = new URL(request.url);
      url.searchParams.delete("salix_control");
      const repair = url.searchParams.get("archive_repair") === "true";
      const forwarded = new Request(url, request);
      // The slot ends at the upgrade response, not when the WS closes. Existing
      // accepted work drains through Connector's persistent execution seal.
      return await this.#control.run(permit, "connect", () => this.#fetchRunning(permit, forwarded),
        (response) => ({ status: response.status }), { sealed: repair });
    } catch (error) {
      if (error instanceof ControlError) return errorJson(error.code, error.status);
      throw error;
    }
  }

  #container(): Container {
    const container = this.ctx.container;
    if (!container) throw new ControlError("container_unavailable", 503);
    return container;
  }

  #fetchRunning(permit: ControlPermit, request: Request): Promise<Response> {
    this.#control.current(permit);
    const container = this.#container();
    if (!container.running) throw new ControlError("container_not_running", 503);
    // Native getTcpPort.fetch does not call SDK startAndWaitForPorts. If the
    // Container stops after this check, return the failure; never auto-start.
    const headers = new Headers(request.headers);
    headers.set("x-salix-control", JSON.stringify(permit));
    return container.getTcpPort(PORT).fetch(new Request(request, { headers }));
  }

  #readRunning(permit: ControlPermit, request: Request): Promise<Response> {
    return this.#fetchRunning(permit, new Request(request, { signal: AbortSignal.timeout(OBSERVATION_TIMEOUT_MS) }));
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
