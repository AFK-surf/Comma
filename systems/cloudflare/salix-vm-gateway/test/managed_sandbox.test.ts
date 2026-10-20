import { describe, expect, test, vi } from "vitest";
import type { ControlPermit } from "../src/control";

// The platform adapter is replaced, not the control implementation. Cloudflare
// native stop/start and eviction semantics still require platform validation.
vi.mock("@cloudflare/sandbox", () => ({
  Sandbox: class {
    envVars = {};
    enableInternet = true;
    entrypoint = undefined;
    constructor(public ctx: { keepAlive?: (enabled: boolean) => Promise<void>; armAlarm?: () => Promise<void> }) {}
    async setKeepAlive(enabled: boolean) { await this.ctx.keepAlive?.(enabled); }
    async scheduleNextAlarm() { await this.ctx.armAlarm?.(); }
    async onStop() {}
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

const station = { SALIX_SERVER: "wss://salix.example", SALIX_WORKLOAD_CREDENTIAL: "connect-credential" };

function harness(running = false) {
  const saved = new Map<string, string>();
  const table = (sql: string) => /salix_container_\w+/.exec(sql)?.[0] ?? "";
  const events: string[] = [];
  // Resolved when the object keeps its Container's next stop.
  const stopKept: ReturnType<typeof deferred<void>>[] = [];
  const nextStop = () => { const kept = deferred<void>(); stopKept.push(kept); return kept.promise; };
  // Nobody may be watching when it ends.
  const running_ = () => { const d = deferred<void>(); d.promise.catch(() => undefined); return d; };
  let exited = running_();
  const container = {
    running,
    start: vi.fn((_options: { env: Record<string, string> }) => { container.running = true; events.push("start"); }),
    destroy: vi.fn(async () => { container.exit(new Error("container destroyed")); }),
    monitor: vi.fn(() => exited.promise),
    // The platform ends the Container by itself.
    exit(error?: Error) { container.running = false; const ended = exited; exited = running_(); if (error) ended.reject(error); else ended.resolve(); },
  };
  const ctx = {
    container,
    events,
    keepAlive: vi.fn(async (_enabled: boolean): Promise<void> => undefined),
    armAlarm: vi.fn(async (): Promise<void> => { events.push("alarm"); }),
    storage: {
      sql: {
        exec: vi.fn((sql: string, value?: string) => {
          if (sql.startsWith("INSERT")) {
            saved.set(table(sql), value!);
            if (table(sql) === "salix_container_stop") stopKept.splice(0).forEach((kept) => kept.resolve());
          }
          return { toArray: () => sql.startsWith("SELECT") && saved.has(table(sql)) ? [{ value: saved.get(table(sql))! }] : [] };
        }),
      },
      sync: vi.fn(async () => undefined),
    },
  };
  const construct = () => new ManagedSandbox(ctx as unknown as DurableObjectState<{}>, {});
  return { sandbox: construct(), construct, container, ctx, nextStop };
}

describe("managed Sandbox platform boundary", () => {
  test("ensure starts the Container once with its station's server and credential, and issuing the start completes it", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    const observed = await h.sandbox.salixEnsure(permit, true, station);
    expect(h.container.start).toHaveBeenCalledTimes(1);
    expect(h.container.start.mock.calls[0][0].env).toMatchObject(station);
    expect(observed).toMatchObject({ running: true, control: { pending: null, last_terminal: { action: "ensure", claim_id: "ensure-1", outcome: "completed" } } });
    await h.sandbox.salixEnsure(claim("again"), true, station);
    expect(h.container.start).toHaveBeenCalledTimes(1);
  });

  test("a start that names an archive gives it to the Container, and a Container that could not restore it is kept as its stop", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    const waking = { ...station, SALIX_RESTORE_ARCHIVE: "H4sIAAAA" };
    await h.sandbox.salixEnsure(permit, true, waking);
    expect(h.container.start.mock.calls[0][0].env).toMatchObject(waking);
    // The entrypoint could not restore the archive: it started no station and exited.
    const kept = h.nextStop();
    h.container.exit(new Error("Container exited with unexpected exit code: 65"));
    await kept;
    expect(h.sandbox.salixObserve()).toMatchObject({ running: false, last_stop: { exit_code: 65, requested: false, operation_id: "wake-1" } });
    // Salix starts another under the same permit, with URLs it signed anew: that start's own.
    const again = { ...station, SALIX_RESTORE_ARCHIVE: "H4sIBBBB" };
    await h.sandbox.salixEnsure(claim("again"), true, again);
    expect(h.container.start).toHaveBeenCalledTimes(2);
    expect(h.container.start.mock.calls[1][0].env).toMatchObject(again);
  });

  // Cloudflare stops a Container shortly after its Durable Object becomes inactive; the SDK's alarm is what keeps the
  // object active, and the native start does not arm it (staging 2026-10-10: every Container gone ~30 s after its start).
  test("ensure arms the alarm that keeps the object active before it starts the Container, and for one found running", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    await h.sandbox.salixEnsure(permit, true, station);
    expect(h.ctx.events).toEqual(["alarm", "start"]);
    // An object that no longer has its alarm (it fired before the start) is asked again: the alarm is armed, nothing starts.
    await h.sandbox.salixEnsure(claim("again"), true, station);
    expect(h.ctx.events).toEqual(["alarm", "start", "alarm"]);
  });

  test("a Container that stops is recorded with what its monitor said, apart from a destroy Salix commanded", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    expect((await h.sandbox.salixEnsure(permit, true, station)).last_stop).toBeNull();
    let kept = h.nextStop();
    h.container.exit(new Error("Container exited with unexpected exit code: 137"));
    await kept;
    expect(h.sandbox.salixObserve().last_stop).toMatchObject({ exit_code: 137, requested: false, operation_id: "wake-1", error: expect.stringContaining("137") });
    expect(h.sandbox.salixObserve().running).toBe(false);

    await h.sandbox.salixEnsure(claim("second"), true, station);
    await h.sandbox.salixSeal(sealing);
    kept = h.nextStop();
    await h.sandbox.salixDestroy(claim("destroy", sealing));
    await kept;
    expect(h.sandbox.salixObserve().last_stop).toMatchObject({ requested: true, operation_id: "archive-1" });
  });

  test("a stop nobody commanded is kept apart: the seal and destroy that follow it do not replace it", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    await h.sandbox.salixEnsure(permit, true, station);
    expect(h.sandbox.salixObserve().last_uncommanded_stop).toBeNull();
    let kept = h.nextStop();
    h.container.exit(new Error("Container exited with unexpected exit code: 137"));
    await kept;
    const lost = { exit_code: 137, requested: false, operation_id: "wake-1", seen_by: "monitor", started_at: expect.any(Number), error: expect.stringContaining("137") };
    expect(h.sandbox.salixObserve()).toMatchObject({ last_stop: lost, last_uncommanded_stop: lost });

    // Salix releases the lost Container as an archive does, wakes it, and later archives it: commanded stops.
    await h.sandbox.salixSeal(sealing);
    await h.sandbox.salixDestroy(claim("release", sealing));
    const woken: ControlPermit = { ...permit, operation_id: "wake-2", revision: 12, claim_id: "ensure-2" };
    await h.sandbox.salixOpen(woken);
    await h.sandbox.salixEnsure(woken, true, station);
    const archiving: ControlPermit = { ...woken, operation_id: "archive-2", revision: 13, claim_id: "seal-2" };
    await h.sandbox.salixSeal(archiving);
    kept = h.nextStop();
    await h.sandbox.salixDestroy(claim("destroy-2", archiving));
    await kept;
    const observed = h.sandbox.salixObserve();
    expect(observed.last_stop).toMatchObject({ requested: true, operation_id: "archive-2" });
    expect(observed.last_uncommanded_stop).toMatchObject(lost);

    // An object made after the Container's start (its own was evicted) is told the stop by the SDK, and says so.
    const later = h.construct();
    await later.onStop({ exitCode: 1, reason: "exit" });
    expect(later.salixObserve().last_uncommanded_stop).toMatchObject({ exit_code: 1, error: "exit", requested: false, seen_by: "sdk", started_at: null });
  });

  test("seal blocks an ensure delayed inside SDK keepAlive before native start", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    const configured = deferred<void>();
    const entered = deferred<void>();
    h.ctx.keepAlive.mockImplementationOnce(() => { entered.resolve(); return configured.promise; });
    const rejected = expect(h.sandbox.salixEnsure(permit, true, station)).rejects.toThrow("stale_control_permit");
    await entered.promise;
    await h.sandbox.salixSeal(sealing);
    configured.resolve();
    await rejected;
    expect(h.container.start).not.toHaveBeenCalled();
    expect(h.sandbox.salixObserve().managed_commands_settled).toBe(false);
  });

  test("destroy needs a seal, and approved disk disposal covers an unresolved ensure", async () => {
    const h = harness();
    await h.sandbox.salixOpen(permit);
    const configured = deferred<void>();
    const entered = deferred<void>();
    h.ctx.keepAlive.mockImplementationOnce(() => { entered.resolve(); return configured.promise; });
    const ensure = h.sandbox.salixEnsure(permit, true, station).catch((error: Error) => error);
    await entered.promise;
    const replacement = h.construct();
    await replacement.salixSeal(sealing);
    await expect(replacement.salixDestroy(claim("normal", sealing))).rejects.toThrow("control_command_unsettled");
    const stopped = await replacement.salixDestroy(claim("discard", sealing), true);
    expect(stopped).toMatchObject({ running: false, managed_commands_settled: true,
      control: { sealed: true, pending: null, last_terminal: { action: "destroy", claim_id: "discard", outcome: "completed" } } });
    configured.resolve();
    expect(await ensure).toBeInstanceOf(Error);
    expect(h.container.start).not.toHaveBeenCalled();
  });

  test("nothing reaches the Container through the gateway, and legacy SDK entrypoints never start it", async () => {
    const h = harness(true);
    await h.sandbox.salixOpen(permit);
    expect((await h.sandbox.fetch()).status).toBe(409);
    for (const method of ["containerFetch", "start", "startAndWaitForPorts", "stop", "destroy", "configure", "setKeepAlive", "createBackup", "restoreBackup"] as const) {
      await expect(h.sandbox[method]()).rejects.toThrow("control_permit_required");
    }
    expect(h.container.start).not.toHaveBeenCalled();
    expect(h.container.destroy).not.toHaveBeenCalled();
  });
});
