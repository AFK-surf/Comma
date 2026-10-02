import { describe, expect, test, vi } from "vitest";
import type { ControlPermit } from "../src/control";

// The platform adapter is replaced, not the control implementation. Cloudflare
// native stop/start and eviction semantics still require the isolated experiment.
vi.mock("@cloudflare/sandbox", () => ({
  Sandbox: class {
    envVars = {};
    enableInternet = true;
    entrypoint = undefined;
    constructor(public ctx: { keepAlive?: (enabled: boolean) => Promise<void> }) {}
    async setKeepAlive(enabled: boolean) { await this.ctx.keepAlive?.(enabled); }
  },
}));

import { ManagedSandbox } from "../src/managed_sandbox";

const permit: ControlPermit = { owner_id: "workload-1", operation_id: "wake-1", generation: 1, revision: 10, claim_id: "ensure-1" };
const sealing: ControlPermit = { ...permit, operation_id: "archive-1", revision: 11, claim_id: "seal-1" };
const claim = (id: string, p = permit) => ({ ...p, claim_id: id });

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((r, fail) => { resolve = r; reject = fail; });
  return { promise, resolve, reject };
}

function harness(running = false) {
  let saved: string | undefined;
  const tcp = vi.fn(async (_request: Request) => new Response("ready"));
  const container = {
    running,
    start: vi.fn(() => { container.running = true; }),
    destroy: vi.fn(async () => { container.running = false; }),
    monitor: vi.fn(() => new Promise<void>(() => {})),
    getTcpPort: vi.fn((_port: number) => ({ fetch: tcp })),
  };
  const ctx = {
    container,
    keepAlive: vi.fn(async (_enabled: boolean): Promise<void> => undefined),
    waitUntil: vi.fn(),
    storage: {
      sql: {
        exec: vi.fn((sql: string, value?: string) => {
          if (sql.startsWith("INSERT")) saved = value;
          return { toArray: () => sql.startsWith("SELECT") && saved ? [{ value: saved }] : [] };
        }),
      },
      sync: vi.fn(async () => undefined),
    },
  };
  const construct = () => new ManagedSandbox(ctx as unknown as DurableObjectState<{}>, {});
  return { sandbox: construct(), construct, container, tcp, ctx };
}

describe("managed Sandbox platform boundary", () => {
  test("an exact native capacity refusal settles its failed start, while a lost monitor does not", async () => {
    for (const [message, settled] of [
      ["There is no container instance that can be provided to this Durable Object, try again later", true],
      ["Network connection lost", false],
    ] as const) {
      const h = harness();
      const ended = deferred<void>();
      h.container.monitor.mockReturnValueOnce(ended.promise);
      h.tcp.mockRejectedValueOnce(new Error("port not listening"));
      await h.sandbox.salixOpen(permit);
      await expect(h.sandbox.salixEnsure(permit, true)).rejects.toThrow("port not listening");
      ended.reject(new Error(message));
      await h.ctx.waitUntil.mock.calls[0][0];
      await h.sandbox.salixSeal(sealing);
      expect(h.sandbox.salixObserve().managed_commands_settled).toBe(settled);
      if (settled) {
        expect(h.sandbox.salixObserve().control?.last_terminal).toMatchObject({ action: "ensure", status: 503 });
        await h.sandbox.salixOpen(claim("retry", { ...sealing, revision: 12 }));
      }
    }
  });

  test("an old monitor cannot settle a later incarnation's start", async () => {
    const h = harness();
    const ended = deferred<void>();
    h.container.monitor.mockReturnValueOnce(ended.promise);
    h.tcp.mockRejectedValueOnce(new Error("port not listening"));
    await h.sandbox.salixOpen(permit);
    await expect(h.sandbox.salixEnsure(permit, true)).rejects.toThrow("port not listening");
    await h.sandbox.salixStatus(permit);
    await h.sandbox.salixSeal(sealing);
    const next = claim("next-start", { ...sealing, generation: 2, revision: 12 });
    await h.sandbox.salixOpen(next);
    h.tcp.mockRejectedValueOnce(new Error("next port not listening"));
    await expect(h.sandbox.salixEnsure(next, true)).rejects.toThrow("next port not listening");
    ended.resolve();
    await h.ctx.waitUntil.mock.calls[0][0];
    expect(h.sandbox.salixObserve().control?.pending?.claim_id).toBe("next-start");
  });

  test("stopped status and receipt never start, configure, or fetch the Container", async () => {
    const h = harness();
    expect(h.sandbox.salixObserve()).toMatchObject({ running: false, control: null, managed_commands_settled: false });
    await h.sandbox.salixOpen(permit);
    await expect(h.sandbox.salixStatus(permit)).rejects.toThrow("container_not_running");
    await expect(h.sandbox.salixReceipt(permit, "snapshot-1")).rejects.toThrow("container_not_running");
    expect(h.container.start).not.toHaveBeenCalled();
    expect(h.ctx.keepAlive).not.toHaveBeenCalled();
    expect(h.tcp).not.toHaveBeenCalled();
  });

  test("a lost start response can be confirmed after eviction, without another start", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    h.tcp.mockRejectedValueOnce(new Error("connection closed"));
    await expect(h.sandbox.salixEnsure(permit, true)).rejects.toThrow("connection closed");
    expect(h.sandbox.salixObserve().control?.pending).toMatchObject({ action: "ensure", start_issued: true });
    const replacement = h.construct();
    expect((await replacement.salixStatus(claim("observe"))).status).toBe(200);
    expect(replacement.salixObserve().control).toMatchObject({ pending: null, last_terminal: { claim_id: "ensure-1", outcome: "completed" } });
    expect(h.container.start).toHaveBeenCalledTimes(1);
  });

  test("only an exact restored import receipt settles response loss after eviction", async () => {
    const h = harness(true);
    await h.sandbox.salixOpen(permit);
    h.tcp.mockRejectedValueOnce(new Error("response lost"));
    await expect(h.sandbox.salixForward(permit, new Request("http://container/archive", { method: "POST" }), "import", "snapshot-1")).rejects.toThrow("response lost");
    const replacement = h.construct();
    await replacement.salixSeal(sealing);
    for (const receipt of [{ operation: "other", phase: "restored", next_offset: 42, sessions: 1 }, { operation: "snapshot-1", phase: "restoring", next_offset: 42, sessions: 1 }]) {
      h.tcp.mockResolvedValueOnce(Response.json(receipt));
      await replacement.salixReceipt(sealing, "snapshot-1");
      expect(replacement.salixObserve().managed_commands_settled).toBe(false);
    }
    h.tcp.mockResolvedValueOnce(Response.json({ operation: "snapshot-1", phase: "restored", next_offset: 42, sessions: 1 }));
    await replacement.salixReceipt(sealing, "snapshot-1");
    expect(replacement.salixObserve()).toMatchObject({ managed_commands_settled: true, control: { pending: null, last_terminal: { action: "import", claim_id: permit.claim_id, archive_operation: "snapshot-1", outcome: "completed" } } });
    expect(h.container.start).not.toHaveBeenCalled();
  });

  test("seal blocks an ensure delayed inside SDK keepAlive before native start", async () => {
    const h = harness(true);
    await h.sandbox.salixOpen(permit);
    const configured = deferred<void>();
    const entered = deferred<void>();
    h.ctx.keepAlive.mockImplementationOnce(() => { entered.resolve(); return configured.promise; });
    const ensure = h.sandbox.salixEnsure(permit, true);
    const rejected = expect(ensure).rejects.toThrow("stale_control_permit");
    await entered.promise;
    // Ready from a previous running disk cannot settle a not-yet-issued start.
    await h.sandbox.salixStatus(claim("observe"));
    expect(h.sandbox.salixObserve().control?.pending).not.toBeNull();
    await h.sandbox.salixSeal(sealing);
    configured.resolve();
    await rejected;
    expect(h.container.start).not.toHaveBeenCalled();
    expect(h.sandbox.salixObserve().managed_commands_settled).toBe(false);
  });

  test("seal does not wait on a long import, but destroy waits for its real response", async () => {
    const h = harness(true);
    await h.sandbox.salixOpen(permit);
    const response = deferred<Response>();
    const entered = deferred<void>();
    h.tcp.mockImplementationOnce(() => { entered.resolve(); return response.promise; });
    const transfer = h.sandbox.salixForward(permit, new Request("http://container/archive", { method: "POST", body: "part" }), "import", "snapshot-1");
    await entered.promise;
    expect((await h.sandbox.salixSeal(sealing)).managed_commands_settled).toBe(false);
    await expect(h.sandbox.salixDestroy(claim("destroy", sealing))).rejects.toThrow("control_command_unsettled");
    expect(h.container.destroy).not.toHaveBeenCalled();
    response.resolve(new Response("receipt"));
    await transfer;
    expect(h.sandbox.salixObserve().managed_commands_settled).toBe(true);
    await h.sandbox.salixDestroy(claim("destroy", sealing));
    expect(h.container.running).toBe(false);
  });

  test("closed admission permits only repair WebSocket handshakes and archive export", async () => {
    const h = harness(true);
    await h.sandbox.salixOpen(permit);
    await h.sandbox.salixSeal(sealing);
    const socket = { stillOpen: true };
    h.tcp.mockResolvedValue({ status: 101, webSocket: socket } as unknown as Response);
    const connect = (p: ControlPermit, repair: boolean) => new Request(`http://container/connect?salix_control=${encodeURIComponent(JSON.stringify(p))}${repair ? "&archive_repair=true" : ""}`, { headers: { upgrade: "websocket" } });
    expect((await h.sandbox.fetch(connect(claim("normal", sealing), false))).status).toBe(409);
    const response = await h.sandbox.fetch(connect(claim("repair", sealing), true));
    expect(response.status).toBe(101);
    expect(h.sandbox.salixObserve().managed_commands_settled).toBe(true);
    expect(socket.stillOpen).toBe(true);
    const forwarded = h.tcp.mock.calls[0][0];
    expect(new URL(forwarded.url).searchParams.get("archive_repair")).toBe("true");
    expect(JSON.parse(forwarded.headers.get("x-salix-control")!)).toMatchObject(claim("repair", sealing));
    h.tcp.mockResolvedValue(new Response("checkpoint"));
    await h.sandbox.salixForward(claim("export", sealing), new Request("http://container/archive/export", { method: "POST", body: "checkpoint" }), "export");
    await expect(h.sandbox.salixForward(claim("import", sealing), new Request("http://container/archive", { method: "POST" }), "import")).rejects.toThrow("control_sealed");
  });

  test("legacy SDK entrypoints and stopped-between-check-and-fetch never fall back to start", async () => {
    const h = harness(true);
    await h.sandbox.salixOpen(permit);
    for (const method of ["containerFetch", "start", "startAndWaitForPorts", "stop", "destroy", "configure", "setKeepAlive", "createBackup", "restoreBackup"] as const) {
      await expect(h.sandbox[method]()).rejects.toThrow("control_permit_required");
    }
    h.tcp.mockImplementationOnce(async () => { h.container.running = false; throw new Error("container stopped"); });
    await expect(h.sandbox.salixReceipt(permit, "snapshot-1")).rejects.toThrow("container stopped");
    expect(h.container.start).not.toHaveBeenCalled();
    expect(h.container.destroy).not.toHaveBeenCalled();
  });
});
