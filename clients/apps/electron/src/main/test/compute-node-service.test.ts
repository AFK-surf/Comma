import { createServer } from "node:http";
import { mainCoreRequests } from "../../test-support/main-core-requests";
import { AccountComputeNodeService } from "../modules/compute-node/account-service";
import type { ComputeNodeState } from "@comma/native-bridge";
import { signedInSessionSnapshotSchema } from "@comma/session-contract";
import {
  ComputeNodeAuthorizationNotFoundError,
  ComputeNodeCloudRefusalError,
} from "../modules/compute-node/install-authorization";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { LocalHostMaintenance } from "../modules/compute-node/host-maintenance";
import {
  AgentVMMHostPreparation,
  HostPreflightError,
  type HostPreparationState,
  resolveHostConfiguration,
} from "../modules/compute-node/host-preparation";
import { HostMaintenanceIncompatibleError } from "../modules/compute-node/host-maintenance-protocol";
import {
  HostRecoveryInterruptsWorkError,
  HostTargetOlderThanDataError,
} from "../modules/compute-node/host-maintenance";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { realMainClock } from "../clock";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AgentVMMCommandAdapter,
  ComputeNodeCommandError,
  ComputeNodeInstallAuthorization,
  ComputeNodeService,
  runCommand,
  type ComputeNodeInstallAuthorizationOwner,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeRuntimeObservation,
} from "../modules/compute-node";

const accountSession = (
  userId: string,
  generation: number,
  audience = "https://api.example.test"
) =>
  signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation,
    revision: generation,
    phase: "signed_in",
    principal: { userId, email: `${userId}@example.test` },
    session: {
      audience,
      sessionId: `session-${generation}`,
      expiresAtEpochSeconds: 1900000000,
    },
  });

class FakeRuntime implements ComputeNodeRuntimeAdapter {
  calls: string[] = [];
  failRepair = false;
  removeUnknown = false;
  provisioned = false;
  observation: ComputeNodeRuntimeObservation = {
    connector: "absent",
    host: "absent",
    readability: "readable",
    salix: "unregistered",
  };

  async observe() {
    return { ...this.observation };
  }
  async install() {
    this.calls.push("install");
    if (this.failRepair) throw new Error("bundle verification failed");
    this.observation = {
      ...this.observation,
      connector: this.provisioned ? "ready" : "stopped",
      host: "ready",
      readability: "readable",
      salix: this.provisioned ? "ready" : "unregistered",
    };
  }
  async enable() {
    this.calls.push("enable");
    this.observation = {
      ...this.observation,
      connector: "ready",
      host: "ready",
      salix: "ready",
    };
  }
  async repair() {
    this.calls.push("repair");
    if (this.failRepair) throw new Error("bundle verification failed");
    this.observation = {
      ...this.observation,
      connector: this.provisioned ? "ready" : "stopped",
      host: "ready",
      readability: "readable",
      salix: this.provisioned ? "ready" : "unregistered",
    };
  }
  async drain() {
    this.calls.push("drain");
    this.observation = {
      ...this.observation,
      connector: "stopped",
      host: "ready",
      registration: "present",
      registrationState: "draining",
    };
  }
  async remove() {
    this.calls.push("remove");
    if (this.removeUnknown) {
      this.observation = {
        ...this.observation,
        connector: "ready",
        host: "stopped",
      };
      throw new ComputeNodeCommandError(
        "Agent VMM command timed out after 15000ms.",
        "outcome_unknown"
      );
    }
    this.observation = {
      ...this.observation,
      connector: "absent",
      host: "ready",
      registration: "present",
      registrationState: "revoked",
      salix: "revoked",
    };
  }
  async resume() {
    this.calls.push("resume");
    this.observation = {
      ...this.observation,
      connector: "ready",
      host: "ready",
    };
  }
}

const testInstallAuthorization = {
  authorize: vi.fn(async () => ({
    descriptor: JSON.stringify({ version: 1 }),
    operationId: "vmm_install_test",
    registrationId: "registration-test",
  })),
  observe: vi.fn(async () => "ready" as const),
  inspect: vi.fn(async () => ({
    authorizationStatus: "handed_off" as const,
    workActivity: "unknown" as const,
    status: "ready" as const,
  })),
  retry: vi.fn(async () => ({
    descriptor: JSON.stringify({ version: 1 }),
    operationId: "vmm_install_test",
    registrationId: "registration-test",
  })),
  configure: vi.fn(async ({ enabled }: { enabled: boolean }) =>
    enabled ? ("processing" as const) : ("stopped" as const)
  ),
  revoke: vi.fn(async () => "removed" as const),
};

/**
 * Main's clock in these tests: continuation timers run only when a test moves the clock (`advance`).
 */
const manual = {
  now: Date.parse("2026-10-21T00:00:00Z"),
  timers: [] as { at: number; run: () => void; cancelled: boolean }[],
};
beforeEach(() => {
  manual.now = Date.parse("2026-10-21T00:00:00Z");
  manual.timers = [];
  vi.spyOn(realMainClock, "now").mockImplementation(() => manual.now);
  vi.spyOn(realMainClock, "setTimer").mockImplementation((ms, run) => {
    const timer = { at: manual.now + ms, run, cancelled: false };
    manual.timers.push(timer);
    return () => {
      timer.cancelled = true;
    };
  });
});

/** Waits until the service's serialized work is idle. */
async function settled(service: ComputeNodeService) {
  const owner = service as unknown as { tail: Promise<unknown> };
  for (;;) {
    const tail = owner.tail;
    await tail;
    await new Promise((resolve) => setImmediate(resolve));
    if (owner.tail === tail) return;
  }
}

/** Moves Main's clock by `ms`, running each due continuation step to completion in order. */
async function advance(service: ComputeNodeService, ms: number) {
  const end = manual.now + ms;
  for (;;) {
    await settled(service);
    const due = manual.timers
      .filter((timer) => !timer.cancelled && timer.at <= end)
      .toSorted((a, b) => a.at - b.at)[0];
    if (!due) break;
    due.cancelled = true;
    manual.now = Math.max(manual.now, due.at);
    due.run();
  }
  manual.now = end;
  await settled(service);
}

/** A process exit: the old service's timers never run. */
const exitProcess = () => manual.timers.forEach((timer) => (timer.cancelled = true));

/** The pending continuation timers. */
const armed = () => manual.timers.filter((timer) => !timer.cancelled);

/**
 * Resolves with the first state a service publishes that `matches`, such as
 * the result of the reconcile that `ComputeNodeService.open` starts.
 */
function publishedState(matches: (state: ComputeNodeState) => boolean) {
  const published = Promise.withResolvers<ComputeNodeState>();
  return {
    state: published.promise,
    onStateChanged: (state: ComputeNodeState) => {
      if (matches(state)) published.resolve(state);
    },
  };
}

describe("ComputeNodeService", () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "comma-compute-node-"));
  });

  afterEach(async () => {
    await rm(tempDir, { force: true, recursive: true });
  });

  it("closes only the confirmed unfinished request before a new connection and never removes local resources", async () => {
    const runtime = new FakeRuntime();
    runtime.failRepair = true;
    const filePath = join(tempDir, "abandon.json");
    const owner = {
      ...testInstallAuthorization,
      authorize: vi.fn(async (_input: { requestId: string; workspaceId: string }) => ({
        descriptor: "{}",
        operationId: "vmm_install_test",
        registrationId: "registration-test",
      })),
      abandon: vi.fn(async () => undefined),
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: owner,
    });
    // A retryable failure stays processing: Main continues the same request by itself.
    expect(
      await service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).toMatchObject({ status: "processing" });
    expect(service.state().canAbandonRequest).toBe(true);
    await expect(
      service.abandon({
        workspaceId: "wrong",
        installationId: "vmm_install_test",
        bindingRevision: service.state().bindingRevision!,
      })
    ).rejects.toThrow();
    expect(owner.abandon).not.toHaveBeenCalled();
    const removed = await service.abandon({
      workspaceId: "workspace",
      installationId: "vmm_install_test",
      bindingRevision: service.state().bindingRevision!,
    });
    expect(removed.status).toBe("removed");
    expect(removed.bindingInstallationId).toBeUndefined();
    expect(owner.abandon).toHaveBeenCalledExactlyOnceWith({
      operationId: "vmm_install_test",
      workspaceId: "workspace",
    });
    expect(runtime.calls).toEqual(["install"]);
    expect(JSON.parse(await readFile(filePath, "utf8"))).not.toHaveProperty(
      "installOperationId"
    );
    runtime.failRepair = false;
    runtime.provisioned = true;
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(service.state().canAbandonRequest).toBe(false);
    const [first, second] = owner.authorize.mock.calls.slice(-2);
    expect(first![0].requestId).not.toBe(second![0].requestId);
  });

  it("saves an accepted authorization only to its original account after the Session changes", async () => {
    const runtime = new FakeRuntime();
    let generation = "original";
    let release!: () => void;
    let entered!: () => void;
    const waiting = new Promise<void>((resolve) => {
      entered = resolve;
    });
    const resume = new Promise<void>((resolve) => {
      release = resolve;
    });
    const filePath = join(tempDir, "late-authorization.json");
    const owner = {
      ...testInstallAuthorization,
      authorize: vi.fn(async () => {
        entered();
        await resume;
        return {
          operationId: "accepted-original",
          registrationId: "original-registration",
          descriptor: "secret-original",
        };
      }),
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: owner,
      authorityGeneration: () => generation,
      accountOwner: { audience: "https://api.example.test", subject: "original" },
    });
    const pending = service.configure({
      desiredEnabled: true,
      workspaceId: "original-workspace",
    });
    const rejected = expect(pending).rejects.toThrow("session changed");
    await waiting;
    generation = "replacement";
    release();
    await rejected;
    const original = JSON.parse(await readFile(filePath, "utf8"));
    expect(original).toMatchObject({
      installOperationId: "accepted-original",
      registrationId: "original-registration",
      accountOwner: { subject: "original" },
      operation: { outcome: "unknown" },
    });
    expect(JSON.stringify(original)).not.toContain("secret-original");
    expect(runtime.calls).not.toContain("install");
  });

  it.each([
    "{unreadable-owner-record",
    JSON.stringify({
      version: 4,
      revision: 1,
      desiredEnabled: true,
      registrationId: 42,
    }),
    " ".repeat(16 * 1024 + 1),
  ])(
    "preserves corrupt or oversized account intent instead of replacing it with a new binding (%#)",
    async (original) => {
      const runtime = new FakeRuntime();
      const filePath = join(tempDir, "corrupt-intent.json");
      await writeFile(filePath, original);
      const service = await ComputeNodeService.open({
        adapter: runtime,
        filePath,
        platform: "darwin",
        arch: "arm64",
        installAuthorization: testInstallAuthorization,
      });
      await expect(
        service.configure({ desiredEnabled: true, workspaceId: "new" })
      ).rejects.toThrow("intent is unreadable");
      expect(await readFile(filePath, "utf8")).toBe(original);
      expect(runtime.calls).toEqual([]);
    }
  );

  it("fences a validated old command before the next local effect, including A to B to A", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    let generation = "A:1";
    let release!: () => void;
    let entered!: () => void;
    const waiting = new Promise<void>((resolve) => {
      entered = resolve;
    });
    const resumed = new Promise<void>((resolve) => {
      release = resolve;
    });
    const owner = {
      ...testInstallAuthorization,
      configure: vi.fn(async () => {
        entered();
        await resumed;
        return "stopped" as const;
      }),
    };
    const filePath = join(tempDir, "fence.json");
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: owner,
      authorityGeneration: () => generation,
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace-A" });
    const confirmation = {
      workspaceId: "workspace-A",
      installationId: "vmm_install_test",
      bindingRevision: service.state().bindingRevision!,
      confirmationId: "A:1",
    };
    runtime.calls = [];
    const pending = service.drain(confirmation);
    const rejected = expect(pending).rejects.toThrow("session changed");
    await waiting;
    generation = "B:2";
    generation = "A:3";
    release();
    await rejected;
    expect(runtime.calls).not.toContain("drain");
    await expect(service.remove(confirmation)).rejects.toThrow("confirmation expired");
    expect(JSON.parse(await readFile(filePath, "utf8")).registrationId).toBe(
      "registration-test"
    );
  });

  it("finds the original unexchanged request after response loss and a new Session, then closes it without local mutation", async () => {
    const audience = "https://api.comma.example";
    const session = {
      state: () => ({
        phase: "signed_in",
        authority: { authorityInstanceId: "authority-A" },
        generation: 3,
        session: { audience, sessionId: "new-A" },
      }),
      acquireProductCredential: () => ({
        audience,
        authorityInstanceId: "authority-A",
        generation: 3,
        sessionId: "new-A",
        signal: new AbortController().signal,
        token: "new-session-token",
      }),
      isCurrentProductCredential: () => true,
      reportUnauthorized: async () => undefined,
    } as never;
    const fetcher = vi.fn(async (input: RequestInfo | URL, options?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path.endsWith("/requests/original-request") && options?.method === "GET")
        return new Response(
          JSON.stringify({
            operation: {
              id: "original-operation",
              registration_id: "original-registration",
              scope_key: "workspace",
              authorization_status: "requested",
            },
          })
        );
      if (path.endsWith("/recovery/abandon") && options?.method === "POST")
        return new Response(
          JSON.stringify({
            operation: { id: "original-operation", authorization_status: "revoked" },
          })
        );
      return new Response("{}", { status: 404 });
    });
    const runtime = new FakeRuntime();
    const filePath = join(tempDir, "lost-request.json");
    await writeFile(
      filePath,
      JSON.stringify({
        version: 4,
        revision: 3,
        desiredEnabled: true,
        workspaceId: "workspace",
        accountOwner: { audience, subject: "original-A" },
        operation: {
          kind: "configure",
          operationId: "original-request",
          outcome: "unknown",
          requestId: "original-request",
          targetRef: "compute-node/local",
          targetRevision: 1,
          connectionEpoch: "1",
          leaseGeneration: 0,
        },
      })
    );
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: new ComputeNodeInstallAuthorization(
        session,
        mainCoreRequests(session, fetcher)
      ),
      accountOwner: { audience, subject: "original-A" },
      authorityGeneration: () => "A:3",
    });
    const checked = await service.refresh();
    expect(checked).toMatchObject({
      canAbandonRequest: true,
      bindingInstallationId: "original-operation",
      issue: "authorization_unavailable",
    });
    expect(fetcher.mock.calls.some(([, options]) => options?.method === "POST")).toBe(
      false
    );
    const completed = await service.abandon({
      workspaceId: "workspace",
      installationId: "original-operation",
      confirmationId: "A:3",
      bindingRevision: checked.bindingRevision!,
    });
    expect(completed.status).toBe("removed");
    expect(runtime.calls).toEqual([]);
    expect(JSON.parse(await readFile(filePath, "utf8"))).not.toHaveProperty(
      "installOperationId"
    );
    expect(
      fetcher.mock.calls.filter(([, options]) => options?.method === "POST")
    ).toHaveLength(1);
  });

  it("preserves a real HTTP revoke accepted after logout and resumes local retirement in the original account", async () => {
    let received!: () => void, respond!: () => void;
    const entered = new Promise<void>((done) => {
      received = done;
    });
    const released = new Promise<void>((done) => {
      respond = done;
    });
    let generation = "A:1",
      current = true;
    const server = createServer(async (request, response) => {
      request.resume();
      if (request.url?.endsWith("/revoke")) {
        received();
        await released;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          operation: {
            authorization_status: request.url?.endsWith("/revoke")
              ? "revoked"
              : "handed_off",
            status: request.url?.endsWith("/revoke") ? "removed" : "ready",
          },
        })
      );
    });
    await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
    const address = server.address() as { port: number };
    const audience = `http://127.0.0.1:${address.port}`;
    const session = {
      state: () => ({
        phase: "signed_in",
        authority: { authorityInstanceId: "authority-A" },
        generation: 1,
        session: { audience, sessionId: "session-A" },
      }),
      acquireProductCredential: () => ({
        audience,
        authorityInstanceId: "authority-A",
        generation: 1,
        sessionId: "session-A",
        signal: new AbortController().signal,
        token: "test-token",
      }),
      isCurrentProductCredential: () => current,
      reportUnauthorized: async () => undefined,
    } as never;
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    runtime.observation = {
      connector: "ready",
      host: "ready",
      readability: "readable",
      salix: "ready",
      registration: "present",
      registrationState: "enabled",
    };
    const filePath = join(tempDir, "http-late.json");
    await writeFile(
      filePath,
      JSON.stringify({
        version: 4,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace-A",
        installOperationId: "install-A",
        installAppliedOperationId: "install-A",
        registrationId: "registration-A",
        accountOwner: { audience, subject: "original-A" },
      })
    );
    const options = {
      adapter: runtime,
      filePath,
      platform: "darwin" as const,
      arch: "arm64",
      installAuthorization: new ComputeNodeInstallAuthorization(
        session,
        mainCoreRequests(session)
      ),
      authorityGeneration: () => generation,
      accountOwner: { audience, subject: "original-A" },
    };
    try {
      const service = await ComputeNodeService.open(options);
      await service.refresh();
      const pending = service.remove({
        workspaceId: "workspace-A",
        installationId: "install-A",
        confirmationId: generation,
        bindingRevision: service.state().bindingRevision!,
      });
      const rejected = expect(pending).rejects.toThrow("session changed");
      await entered;
      generation = "B:2";
      current = false;
      respond();
      await rejected;
      const original = JSON.parse(await readFile(filePath, "utf8"));
      expect(original).toMatchObject({
        remoteRevocationConfirmed: true,
        accountOwner: { subject: "original-A" },
        operation: { kind: "remove", outcome: "unknown" },
      });
      expect(runtime.calls).not.toContain("remove");
      generation = "A:3";
      current = true;
      const reopened = await ComputeNodeService.open(options);
      await reopened.refresh();
      const completed = await reopened.remove({
        workspaceId: "workspace-A",
        installationId: "install-A",
        confirmationId: generation,
        bindingRevision: reopened.state().bindingRevision!,
      });
      expect(completed.status).toBe("removed");
      expect(runtime.calls.filter((call) => call === "remove")).toHaveLength(1);
    } finally {
      respond();
      server.closeAllConnections();
      await new Promise<void>((done) => server.close(() => done()));
    }
  });

  it("expires a removal confirmation when the same binding changes, while read-only refresh keeps it valid", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const revoke = vi.fn(testInstallAuthorization.revoke);
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath: join(tempDir, "revision.json"),
      platform: "darwin",
      arch: "arm64",
      installAuthorization: { ...testInstallAuthorization, revoke },
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    const confirmation = {
      workspaceId: "workspace",
      installationId: "vmm_install_test",
      bindingRevision: service.state().bindingRevision!,
    };
    await service.refresh();
    expect(service.state().bindingRevision).toBe(confirmation.bindingRevision);
    await service.drain(confirmation);
    const calls = [...runtime.calls];
    await expect(service.remove(confirmation)).rejects.toThrow("confirmation expired");
    expect(runtime.calls).toEqual(calls);
    expect(revoke).not.toHaveBeenCalled();
  });

  it("clears account projections immediately and preserves separate intent through account and audience changes", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const revoke = vi.fn(testInstallAuthorization.revoke);
    const service = new AccountComputeNodeService(
      {
        adapter: runtime,
        filePath: join(tempDir, "account.json"),
        platform: "darwin",
        arch: "arm64",
        installAuthorization: { ...testInstallAuthorization, revoke },
      },
      accountSession("A", 1)
    );
    await service.configure({ desiredEnabled: true, workspaceId: "workspace-A" });
    const old = {
      workspaceId: "workspace-A",
      installationId: "vmm_install_test",
      bindingRevision: service.state().bindingRevision!,
      confirmationId: service.state().confirmationId,
    };
    service.sessionChanged(accountSession("B", 2));
    expect(service.state()).toMatchObject({
      desiredEnabled: false,
      facets: { workActivity: "unknown" },
    });
    expect(service.state().bindingWorkspaceId).toBeUndefined();
    await expect(service.remove(old)).rejects.toThrow("confirmation expired");
    expect(revoke).not.toHaveBeenCalled();
    await service.configure({ desiredEnabled: true, workspaceId: "workspace-B" });
    service.sessionChanged(accountSession("A", 3));
    expect(service.state().bindingWorkspaceId).toBeUndefined();
    await service.refresh();
    expect(service.state().bindingWorkspaceId).toBe("workspace-A");
    await expect(service.remove(old)).rejects.toThrow("confirmation expired");
    service.sessionChanged(accountSession("A", 4, "https://another.example.test"));
    await service.refresh();
    expect(service.state().bindingWorkspaceId).toBeUndefined();
  });

  it.each([false, true])(
    "after a reset, never replays a consumed install: replaces its lost registration, or finishes exact removal (enrollment interrupted: %s)",
    async (interrupted) => {
      const directory = await mkdtemp(join(tmpdir(), "comma-reset-binding-"));
      const runtime = new FakeRuntime();
      runtime.provisioned = true;
      const policyDirectory = join(directory, "maintenance");
      const maintenance = new LocalHostMaintenance(
        new AgentVMMHostPreparation(
          resolveHostConfiguration("prod", {}, directory),
          vi.fn()
        ),
        policyDirectory,
        vi.fn()
      );
      const revoke = vi.fn(async () => "removed" as const);
      let installation = 0;
      const authorize = vi.fn(async () => ({
        descriptor: "{}",
        operationId: `install-${++installation}`,
        registrationId: `registration-${installation}`,
      }));
      const options = {
        adapter: runtime,
        filePath: join(directory, "intent.json"),
        platform: "darwin" as const,
        arch: "arm64",
        installAuthorization: { ...testInstallAuthorization, authorize, revoke },
      };
      const open = () =>
        new AccountComputeNodeService(
          options,
          accountSession("A", 1),
          undefined,
          maintenance
        );
      try {
        let service = open();
        runtime.failRepair = interrupted;
        const initial = service.configure({
          desiredEnabled: true,
          workspaceId: "workspace-A",
        });
        if (interrupted) expect(await initial).toMatchObject({ status: "processing" });
        else await initial;
        runtime.failRepair = false;
        // The local owner reset the Host, permanently fencing its old install request.
        await mkdir(policyDirectory, { recursive: true });
        await writeFile(
          join(policyDirectory, "state.json"),
          JSON.stringify({
            version: 1,
            uninstalled: false,
            blockedInstalls: { "install-1": true },
          })
        );
        runtime.observation = {
          host: "ready",
          connector: "absent",
          salix: "unregistered",
          readability: "readable",
          registration: "absent",
        };
        const calls = [...runtime.calls];
        service = open();
        if (!interrupted) {
          // The applied installation lost its registration with the reset: Main retires it exactly and starts one
          // new installation under a new operation, never the fenced one.
          await service.refresh();
          const [inner] = (
            service as unknown as { services: Map<string, Promise<ComputeNodeService>> }
          ).services.values();
          await advance(await inner!, 0);
          expect(revoke).toHaveBeenCalledExactlyOnceWith({
            operationId: "install-1",
            workspaceId: "workspace-A",
          });
          expect(authorize).toHaveBeenCalledTimes(2);
          expect(runtime.calls.slice(calls.length)).toEqual(["install"]);
          expect(service.state()).toMatchObject({
            status: "ready",
            bindingInstallationId: "install-2",
          });
          return;
        }
        // An install that never applied keeps its accepted cloud handoff: neither the reset nor a restart revokes it.
        const blocked = await service.refresh();
        expect(blocked).toMatchObject({
          status: "action_required",
          issue: "removal_incomplete",
          recoveryActions: ["finish_remove", "check_status"],
          bindingInstallationId: "install-1",
        });
        expect(blocked.canAbandonRequest).toBe(false);
        await service.configure({ desiredEnabled: true, workspaceId: "workspace-A" });
        expect(runtime.calls).toEqual(calls);
        expect(authorize).toHaveBeenCalledTimes(1);
        expect(revoke).not.toHaveBeenCalled();
        const confirmation = {
          workspaceId: "workspace-A",
          installationId: "install-1",
          bindingRevision: service.state().bindingRevision!,
          confirmationId: service.state().confirmationId,
        };
        revoke.mockRejectedValueOnce(new Error("cloud unavailable"));
        await expect(service.remove(confirmation)).rejects.toThrow("cloud unavailable");
        expect(service.state().bindingInstallationId).toBe("install-1");
        const removed = await service.remove({
          ...confirmation,
          bindingRevision: service.state().bindingRevision!,
        });
        expect(removed.status).toBe("removed");
        expect(revoke).toHaveBeenLastCalledWith({
          operationId: "install-1",
          workspaceId: "workspace-A",
        });
        expect(runtime.calls).toEqual(calls); // Already absent. Do not touch other local registrations.
        await service.configure({ desiredEnabled: true, workspaceId: "workspace-A" });
        expect(service.state()).toMatchObject({
          status: "ready",
          bindingInstallationId: "install-2",
        });
        expect(authorize).toHaveBeenCalledTimes(2);
        expect(
          JSON.parse(await readFile(join(policyDirectory, "state.json"), "utf8"))
            .blockedInstalls["install-1"]
        ).toBe(true);
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    }
  );

  it.each([
    ["configure", false],
    ["repair", false],
    ["rebuild", false],
    ["configure", true],
    ["repair", true],
    ["rebuild", true],
  ] as const)(
    "fences %s across an awaited maintenance gate (return to A: %s)",
    async (action, returnToA) => {
      const directory = await mkdtemp(join(tmpdir(), "comma-maintenance-session-"));
      const runtime = new FakeRuntime();
      const authorize = vi.fn(async () => testInstallAuthorization.authorize());
      const maintenance = new LocalHostMaintenance(
        new AgentVMMHostPreparation(
          resolveHostConfiguration("prod", {}, directory),
          vi.fn()
        ),
        join(directory, "maintenance"),
        vi.fn()
      );
      let entered!: () => void, release!: () => void;
      const gateEntered = new Promise<void>((resolve) => {
        entered = resolve;
      });
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      const check = vi
        .spyOn(maintenance, "assertInstallationAllowed")
        .mockImplementation(async () => {
          entered();
          await gate;
        });
      try {
        const service = new AccountComputeNodeService(
          {
            adapter: runtime,
            filePath: join(directory, "intent.json"),
            platform: "darwin",
            arch: "arm64",
            installAuthorization: { ...testInstallAuthorization, authorize },
          },
          accountSession("A", 1),
          undefined,
          maintenance
        );
        const request =
          action === "configure"
            ? service.configure({ desiredEnabled: true, workspaceId: "private-A" })
            : service[action]();
        const rejected = expect(request).rejects.toThrow("session changed");
        await gateEntered;
        service.sessionChanged(accountSession("B", 2));
        if (returnToA) service.sessionChanged(accountSession("A", 3));
        release();
        await rejected;
        expect(runtime.calls).toEqual([]);
        expect(authorize).not.toHaveBeenCalled();
        expect(service.state().bindingWorkspaceId).toBeUndefined();
      } finally {
        check.mockRestore();
        await rm(directory, { recursive: true, force: true });
      }
    }
  );

  it.each(["inaccessible", "revoked"] as const)(
    "completes exact absent binding cleanup when remote is %s and permits an explicit new setup",
    async (remote) => {
      const filePath = join(tempDir, "absent.json");
      await writeFile(
        filePath,
        JSON.stringify({
          version: 3,
          revision: 87,
          desiredEnabled: true,
          workspaceId: "workspace",
          installOperationId: "old-operation",
          registrationId: "absent-registration",
        })
      );
      const runtime = new FakeRuntime();
      runtime.provisioned = true;
      runtime.observation = {
        connector: "absent",
        host: "ready",
        readability: "readable",
        salix: "unregistered",
        registration: "absent",
      };
      const revoke = vi.fn(async () => {
        if (remote === "inaccessible")
          throw new ComputeNodeAuthorizationNotFoundError();
        return "removed" as const;
      });
      const owner = { ...testInstallAuthorization, revoke };
      const service = await ComputeNodeService.open({
        adapter: runtime,
        filePath,
        platform: "darwin",
        arch: "arm64",
        installAuthorization: owner,
      });
      const removed = await service.remove();
      expect(removed).toMatchObject({
        status: "removed",
        remoteRevocationConfirmed: remote === "revoked",
      });
      const originalReceipt =
        remote === "inaccessible"
          ? join(
              `${filePath}.removals`,
              `${Buffer.from(removed.operation!.requestId).toString("base64url")}.json`
            )
          : undefined;
      if (originalReceipt) {
        expect(JSON.parse(await readFile(originalReceipt, "utf8"))).toMatchObject({
          installOperationId: "old-operation",
          registrationId: "absent-registration",
          remoteRevocationConfirmed: false,
        });
      }
      expect(runtime.calls).not.toContain("remove");
      await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
      expect(service.state()).toMatchObject({
        bindingInstallationId: "vmm_install_test",
      });
      if (originalReceipt)
        expect(JSON.parse(await readFile(originalReceipt, "utf8"))).toMatchObject({
          installOperationId: "old-operation",
          registrationId: "absent-registration",
        });
    }
  );

  it("preserves the exact binding when the local registration cannot be read", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tempDir, "unreadable.json");
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: testInstallAuthorization,
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    runtime.observation.registration = "unreadable";
    runtime.observation.readability = "unreadable";
    runtime.calls = [];
    await expect(service.remove()).rejects.toThrow("could not be read");
    expect(runtime.calls).toEqual([]);
    expect(JSON.parse(await readFile(filePath, "utf8"))).toMatchObject({
      registrationId: "registration-test",
      remoteRevocationConfirmed: true,
    });
  });

  it("persists remote revocation before local failure and resumes it without cloud authority", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tempDir, "revocation.json");
    const revoke = vi.fn(async () => "removed" as const);
    const authorization = { ...testInstallAuthorization, revoke };
    const options = {
      adapter: runtime,
      filePath,
      platform: "darwin" as const,
      arch: "arm64",
      installAuthorization: authorization,
    };
    const service = await ComputeNodeService.open(options);
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    runtime.removeUnknown = true;
    await expect(service.remove()).rejects.toThrow("timed out");
    expect(JSON.parse(await readFile(filePath, "utf8")).remoteRevocationConfirmed).toBe(
      true
    );
    revoke.mockRejectedValue(new Error("cloud offline"));
    runtime.removeUnknown = false;
    const restarted = await ComputeNodeService.open(options);
    await expect(restarted.remove()).resolves.toMatchObject({
      status: "removed",
      remoteRevocationConfirmed: true,
    });
    expect(revoke).toHaveBeenCalledTimes(1);
  });

  it("coalesces fresh reads without changing lifecycle intent or stopping independent work", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tempDir, "read.json");
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: testInstallAuthorization,
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    const before = await readFile(filePath, "utf8");
    runtime.calls = [];
    const observe = vi.spyOn(runtime, "observe");
    runtime.observation.connector = "degraded";
    const first = service.refresh();
    const second = service.refresh();
    expect(first).toBe(second);
    const state = await first;
    expect(observe).toHaveBeenCalledTimes(1);
    expect(runtime.calls).toEqual([]);
    expect(await readFile(filePath, "utf8")).toBe(before);
    expect(state.bindingWorkspaceId).toBe("workspace");
    expect(state.facets.workActivity).toBe("unknown");
    // The read changed nothing; the node left ready, so one continuation step is armed.
    expect(state.status).toBe("processing");
    expect(armed()).toHaveLength(1);
    vi.clearAllMocks();
  });

  it("publishes each initial Shell phase advance by itself, without a renderer refresh or reenrollment", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    let shellPhase: "preparing" | "failed" | "ready" = "preparing";
    const owner = {
      ...testInstallAuthorization,
      inspect: vi.fn(async () => ({
        authorizationStatus: "handed_off" as const,
        status: "ready" as const,
        workActivity: "idle" as const,
        shellPhase,
      })),
    };
    const published: ComputeNodeState[] = [];
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath: join(tempDir, "shell-phase.json"),
      platform: "darwin",
      arch: "arm64",
      installAuthorization: owner,
      onStateChanged: (state) => published.push(state),
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(service.state()).toMatchObject({
      status: "ready",
      setup: { connection: "ready", shell: "preparing" },
      recoveryActions: ["check_status"],
    });
    // Main waits for the server's Shell on its one timer: 1 s, then 2 s.
    expect(armed()).toHaveLength(1);
    owner.inspect.mockRejectedValueOnce(new Error("Temporary status timeout"));
    await advance(service, 1_000);
    expect(service.state().setup?.connection).toBe("unknown");
    expect(armed()).toHaveLength(1);
    runtime.calls = [];
    shellPhase = "ready";
    published.length = 0;
    await advance(service, 2_000);
    expect(published.at(-1)).toMatchObject({
      status: "ready",
      setup: { connection: "ready", shell: "ready" },
    });
    expect(armed()).toHaveLength(0);
    expect(runtime.calls).toEqual([]);
    // The server owns a failed Shell's retry: Main reports it and does not poll or re-enroll.
    shellPhase = "failed";
    await service.refresh();
    expect(service.state().recoveryActions).toEqual(["check_status"]);
    expect(armed()).toHaveLength(0);
  });

  it("prepares Host before enrollment and continues the same setup by itself after a failure and a restart", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const authorization = {
      ...testInstallAuthorization,
      authorize: vi.fn(testInstallAuthorization.authorize),
    };
    let unavailable = true;
    const idle: HostPreparationState = {
      source: "download",
      location: "https://example.test/Host.zip",
      instance: "shared",
      phase: "idle",
    };
    const preparation = {
      state: () => idle,
      ensure: vi.fn(
        async (
          report: (state: HostPreparationState) => void,
          _options?: { deadline?: number }
        ) => {
          if (unavailable) {
            report({ ...idle, phase: "failed", error: "download unavailable" });
            throw new Error("download unavailable");
          }
          expect(authorization.authorize).not.toHaveBeenCalled();
        }
      ),
      rebuild: vi.fn(async () => {}),
    };
    const filePath = join(tempDir, "preparation.json");
    const options = {
      adapter: runtime,
      preparation,
      filePath,
      installAuthorization: authorization,
      platform: "darwin" as const,
      arch: "arm64",
    };
    let service = await ComputeNodeService.open(options);
    const started = manual.now;
    const first = await service.configure({
      desiredEnabled: true,
      workspaceId: "workspace",
    });
    expect(first).toMatchObject({
      status: "processing",
      preparation: { phase: "failed", error: "download unavailable" },
      deadlineAt: new Date(started + 45 * 60_000).toISOString(),
    });
    // The preparation receives the operation's one overall deadline.
    expect(preparation.ensure.mock.calls[0]![1]).toEqual({
      deadline: started + 45 * 60_000,
    });
    expect(runtime.calls).toEqual([]);
    expect(authorization.authorize).not.toHaveBeenCalled();
    await advance(service, 0);
    expect(preparation.ensure).toHaveBeenCalledTimes(2);
    // A restart is a trigger: the startup step continues the same plan.
    exitProcess();
    service = await ComputeNodeService.open(options);
    unavailable = false;
    await advance(service, 30_000);
    expect(service.state()).toMatchObject({ status: "ready" });
    expect(authorization.authorize).toHaveBeenCalledOnce();
    expect(runtime.calls).toEqual(["install"]);
    expect(armed()).toHaveLength(0);
  });

  it("stops after its attempt budget, asks for one retry, and the retry continues the same request", async () => {
    const runtime = new FakeRuntime();
    runtime.failRepair = true;
    const authorization = {
      ...testInstallAuthorization,
      authorize: vi.fn(testInstallAuthorization.authorize),
      retry: vi.fn(testInstallAuthorization.retry),
      inspect: vi.fn(async () =>
        runtime.failRepair
          ? {
              authorizationStatus: "requested" as const,
              status: "processing" as const,
              workActivity: "unknown" as const,
            }
          : {
              authorizationStatus: "handed_off" as const,
              status: "ready" as const,
              workActivity: "idle" as const,
            }
      ),
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath: join(tempDir, "budget.json"),
      platform: "darwin",
      arch: "arm64",
      installAuthorization: authorization,
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    await advance(service, 10 * 60_000);
    // One explicit attempt, then 12 automatic attempts over about four minutes of backoff.
    expect(runtime.calls.filter((call) => call === "install")).toHaveLength(13);
    expect(authorization.authorize).toHaveBeenCalledOnce();
    expect(authorization.retry).toHaveBeenCalledTimes(12);
    // The last attempt's own cause names why the budget ended.
    expect(service.state()).toMatchObject({
      status: "action_required",
      problem: "setup_failed",
      issue: "retry_budget_exhausted",
      recoveryActions: ["continue_enable", "check_status"],
    });
    expect(armed()).toHaveLength(0);
    runtime.failRepair = false;
    runtime.provisioned = true;
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    // The retry continues the same installation; it requests no new authorization.
    expect(authorization.authorize).toHaveBeenCalledOnce();
    expect(service.state()).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_test",
    });
  });

  it.each(
    [
      {
        name: "does not infer Salix readiness from a loaded connector process",
        salixReady: false,
      },
      {
        name: "does not infer readiness from the legacy helper facts shape",
        salixReady: true,
      },
    ].map((row) => [row.name, row] as [string, typeof row])
  )("%s", async (_name, { salixReady }) => {
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", async () =>
      JSON.stringify({
        connectorInstalled: true,
        connectorLoaded: true,
        hostInstalled: true,
        hostLoaded: true,
        salixReady,
        salixRevoked: false,
        registrationRead: "present",
        registrationState: "enabled",
      })
    );

    await expect(adapter.observe()).resolves.toEqual({
      connector: "ready",
      host: "stopped",
      readability: "readable",
      salix: "unregistered",
    });
  });

  it.each([undefined, false, true])(
    "observes host readiness independently of standalone appliance facts (%s)",
    async (applianceHealthy) => {
      const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", async () =>
        JSON.stringify({
          connectorInstalled: true,
          connectorLoaded: true,
          hostInstalled: true,
          hostLoaded: true,
          hostReadable: true,
          hostHealthy: true,
          applianceInstalled: applianceHealthy,
          applianceHealthy,
          controllerActive: false,
          inventoryComplete: false,
          salixReady: true,
          salixRevoked: false,
          registrationRead: "present",
          registrationState: "enabled",
        })
      );

      await expect(adapter.observe()).resolves.toMatchObject({
        connector: "ready",
        host: "ready",
        salix: "unregistered",
      });
    }
  );

  it("reads the current product registration without scanning other connectors", async () => {
    const run = vi.fn(async () =>
      JSON.stringify({
        hostInstalled: true,
        hostLoaded: true,
        hostReadable: true,
        hostHealthy: true,
        connectorInstalled: true,
        connectorLoaded: false,
        registrationRead: "present",
        registrationState: "enabled",
      })
    );
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", run);
    await expect(adapter.observe("comma-registration")).resolves.toMatchObject({
      host: "ready",
      connector: "stopped",
    });
    expect(run).toHaveBeenCalledWith("/unused/lifecycle", [
      "status",
      "--service-type",
      "agent",
      "--registration-id",
      "comma-registration",
    ]);
  });

  it("reads lifecycle failure stage without exposing its private message", async () => {
    const result = {
      failureCode: "install_failed",
      failureStage: "install-managed",
      failureMessage: "private-native-token",
    };
    await expect(
      runCommand(process.execPath, [
        "-e",
        `process.stdout.write(${JSON.stringify(JSON.stringify(result))}); process.exit(1)`,
      ])
    ).rejects.toMatchObject({
      native: { code: "install_failed", reason: "install-managed" },
    });
  });

  it("keeps failed cloud setup on the same request and marks the connection step failed", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-cloud-failure-"));
    const runtime = new FakeRuntime();
    runtime.observation.host = "ready";
    const authorize = vi.fn(async () => {
      throw new ComputeNodeCommandError(
        "Workspace service unavailable.",
        "outcome_unknown",
        { code: "cloud_unavailable", reason: "cloud_unavailable" }
      );
    });
    try {
      const service = new AccountComputeNodeService(
        {
          adapter: runtime,
          filePath: join(directory, "intent.json"),
          platform: "darwin",
          arch: "arm64",
          installAuthorization: { ...testInstallAuthorization, authorize },
        },
        accountSession("A", 1)
      );
      // An unreachable service is retryable: setup stays processing and continues by itself.
      expect(
        await service.configure({ desiredEnabled: true, workspaceId: "workspace" })
      ).toMatchObject({
        status: "processing",
        setup: { components: "ready", connection: "failed" },
        operation: { kind: "configure", outcome: "unknown" },
      });
      const request = service.state().operation?.requestId;
      await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
      expect(service.state().operation?.requestId).toBe(request);
      expect(authorize).toHaveBeenCalledTimes(2);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("reports local enrollment failure after components are installed without leaking native details", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-enrollment-failure-"));
    const runtime = new FakeRuntime();
    runtime.observation.host = "ready";
    runtime.install = async () => {
      throw new ComputeNodeCommandError(
        "private TLS endpoint and token",
        "command_failed",
        {
          code: "transient_unavailable",
          reason: "register",
        }
      );
    };
    try {
      const service = new AccountComputeNodeService(
        {
          adapter: runtime,
          filePath: join(directory, "intent.json"),
          platform: "darwin",
          arch: "arm64",
          installAuthorization: testInstallAuthorization,
        },
        accountSession("A", 1)
      );
      expect(
        await service.configure({ desiredEnabled: true, workspaceId: "workspace" })
      ).toMatchObject({ status: "processing" });
      expect(service.state().setup).toMatchObject({ components: "ready" });
      expect(service.state().operation?.outcome).toBe("failed");
      expect(JSON.stringify(service.state())).not.toContain(
        "private TLS endpoint and token"
      );
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("reads exact Native retry exhaustion after restart and never resumes a terminal install", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-terminal-install-"));
    const filePath = join(directory, "intent.json");
    await writeFile(
      filePath,
      JSON.stringify({
        version: 3,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        installOperationId: "vmm_install_test",
        registrationId: "registration-test",
      })
    );
    let operationId = "unrelated-install";
    let retryable = false;
    const run = vi.fn(async (_file: string, args: string[]) => {
      if (args[0] !== "status")
        throw new Error("must not resume terminal installation");
      return JSON.stringify({
        hostInstalled: true,
        hostLoaded: true,
        hostReadable: true,
        hostHealthy: true,
        connectorInstalled: true,
        connectorLoaded: false,
        registrationRead: "present",
        registrationState: "enabled",
        operation: {
          operationId,
          kind: "install-managed",
          outcome: "failed",
          failureStage: "register",
          failureCode: retryable ? "transient_unavailable" : "retry_limit_reached",
          ...(retryable ? { retryable: true } : {}),
          attempt: retryable ? 2 : 3,
          failureMessage: "private-endpoint-token",
        },
      });
    });
    const options = {
      filePath,
      adapter: new AgentVMMCommandAdapter("/unused", run),
      platform: "darwin" as const,
      arch: "arm64",
      installAuthorization: {
        ...testInstallAuthorization,
        observe: vi.fn(async () => "processing" as const),
      },
    };
    try {
      const service = await ComputeNodeService.open(options);
      expect((await service.refresh()).problem).not.toBe("connection_retry_limit");
      operationId = "vmm_install_test";
      retryable = true;
      const recoverable = await ComputeNodeService.open(options);
      const pending = await recoverable.refresh();
      expect(pending.recoveryActions).toEqual(["continue_enable", "check_status"]);
      expect(pending.problem).toBe("connection_failed");
      retryable = false;
      const restarted = await ComputeNodeService.open(options);
      const state = await restarted.refresh();
      expect(state.status).toBe("action_required");
      expect(state.setup?.connection).toBe("failed");
      expect(state.recoveryActions).toEqual(["check_status"]);
      expect(state.problem).toBe("connection_retry_limit");
      expect(JSON.stringify(state)).not.toContain("private-endpoint-token");
      await restarted.configure({ desiredEnabled: true, workspaceId: "workspace" });
      expect(run.mock.calls.every(([, args]) => args[0] === "status")).toBe(true);
      expect(JSON.parse(await readFile(filePath, "utf8")).installOperationId).toBe(
        "vmm_install_test"
      );
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("bounds a hung lifecycle helper", async () => {
    await expect(
      runCommand(
        process.execPath,
        ["-e", "setInterval(() => {}, 1000)"],
        undefined,
        50,
        {
          clock: {
            now: () => Date.now(),
            setTimer: (ms, run) => {
              const timer = setTimeout(run, ms);
              return () => clearTimeout(timer);
            },
          },
        }
      )
    ).rejects.toThrow("timed out");
  });

  it("pipes the operation descriptor to the helper without putting it in argv", async () => {
    const run = vi.fn(
      async (_command: string, _args: string[], _stdin?: string, _timeoutMs?: number) =>
        ""
    );
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", run);
    const descriptor = JSON.stringify({
      operation_id: "vmm_install_test",
      one_time_secret: "secret-value",
      version: 1,
    });

    await adapter.install("vmm_install_test", descriptor);

    expect(run).toHaveBeenCalledWith(
      "/unused/lifecycle",
      [
        "install",
        "--service-type",
        "agent",
        "--request-id",
        "vmm_install_test",
        "--operation-stdin",
      ],
      descriptor,
      180_000
    );
    expect(run.mock.calls[0]?.[1].join(" ")).not.toContain("secret-value");
  });

  it("does not turn a missing post-install registration into an install resume", async () => {
    const run = vi
      .fn()
      .mockRejectedValue(new Error("managed registration is not readable"));
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", run);

    await expect(
      adapter.enable("local-enable-1", "external-registration-1")
    ).rejects.toThrow("managed registration is not readable");

    expect(run.mock.calls).toEqual([
      [
        "/unused/lifecycle",
        [
          "registration-state",
          "--service-type",
          "agent",
          "--registration-id",
          "external-registration-1",
          "--state",
          "enabled",
          "--request-id",
          "local-enable-1",
        ],
      ],
    ]);
  });

  it("keeps the last-known observation when the lifecycle helper becomes unreadable", async () => {
    let calls = 0;
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", async () => {
      calls += 1;
      if (calls === 1) {
        return JSON.stringify({
          connectorInstalled: true,
          connectorLoaded: true,
          hostInstalled: true,
          hostLoaded: true,
          salixReady: true,
          salixRevoked: false,
          registrationRead: "present",
          registrationState: "enabled",
        });
      }
      throw new Error("permission denied");
    });

    await expect(adapter.observe()).resolves.toMatchObject({
      connector: "ready",
      host: "stopped",
      readability: "readable",
      salix: "unregistered",
    });
    await expect(adapter.observe()).resolves.toMatchObject({
      connector: "ready",
      host: "stopped",
      readability: "unreadable",
      salix: "unregistered",
    });
  });

  it("does not treat generic ready observation as proof of a timed-out install", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    runtime.install = async () => {
      runtime.calls.push("install");
      runtime.observation = {
        connector: "ready",
        host: "ready",
        readability: "readable",
        salix: "ready",
      };
      throw new ComputeNodeCommandError(
        "Agent VMM command timed out after 15000ms.",
        "outcome_unknown"
      );
    };
    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "unknown.json"),
      platform: "darwin",
    });

    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).rejects.toThrow("timed out");
    expect(service.state()).toMatchObject({
      desiredEnabled: true,
      operation: { outcome: "unknown", kind: "configure" },
      status: "action_required",
    });
    expect(runtime.calls).toEqual(["install"]);
  });
  it("persists desired intent and reconciles restart and drain", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tempDir, "intent.json");
    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });

    expect(service.state().status).toBe("not_set");
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({
      desiredEnabled: true,
      facets: { workActivity: "unknown" },
      operation: { connectionEpoch: expect.stringMatching(/^[1-9][0-9]*$/) },
      status: "ready",
    });
    expect(runtime.calls).toEqual(["install"]);

    const reconciled = publishedState((state) => state.status === "ready");
    const restarted = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
      onStateChanged: reconciled.onStateChanged,
    });
    expect(await reconciled.state).toMatchObject({
      desiredEnabled: true,
      status: "ready",
    });
    await expect(restarted.drain()).resolves.toMatchObject({ status: "stopped" });
    await restarted.configure({ desiredEnabled: true, workspaceId: "wsp_test" });
    await expect(restarted.drain()).resolves.toMatchObject({ status: "stopped" });
    expect(runtime.calls.slice(-3)).toEqual(["drain", "enable", "drain"]);
    expect(restarted.state()).toMatchObject({
      desiredEnabled: false,
      observed: {
        connector: "stopped",
        host: "ready",
        readability: "readable",
        salix: "ready",
      },
      status: "stopped",
    });
  });

  it("resumes an acknowledged install after enrollment failure without replacing its identity", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    runtime.install = async () => {
      runtime.calls.push("install");
      runtime.observation = {
        ...runtime.observation,
        host: "ready",
        connector: "stopped",
      };
      throw new ComputeNodeCommandError(
        "enrollment transport failed",
        "command_failed"
      );
    };
    const authorize = vi.fn(async () => ({
      descriptor: "{}",
      operationId: "vmm_install_test",
      registrationId: "registration-test",
    }));
    const filePath = join(tempDir, "ack.json");
    const options = {
      adapter: runtime,
      arch: "arm64",
      platform: "darwin" as const,
      filePath,
      installAuthorization: { ...testInstallAuthorization, authorize },
    };
    const service = await ComputeNodeService.open(options);
    expect(
      await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).toMatchObject({ status: "processing" });
    // Match the existing shipped intent that classified an ACK as a lost receipt.
    const intent = JSON.parse(await readFile(filePath, "utf8"));
    await writeFile(filePath, JSON.stringify({ ...intent, receiptMissing: true }));
    exitProcess();
    const restarted = await ComputeNodeService.open(options);
    await restarted.refresh();
    expect(restarted.state().recoveryActions).toContain("continue_enable");
    await expect(
      restarted.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({ status: "ready" });
    expect(runtime.calls).toEqual(["install", "resume", "enable"]);
    expect(authorize).toHaveBeenCalledTimes(1);
    const completed = JSON.parse(await readFile(filePath, "utf8"));
    expect(completed.installOperationId).toBe(intent.installOperationId);
    expect(completed.registrationId).toBe(intent.registrationId);
    expect(completed.receiptMissing).toBeUndefined();
  });

  it("re-enables a stopped registration even when its existing Shell is ready", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const configure = vi.fn(async ({ enabled }: { enabled: boolean }) =>
      enabled ? ("processing" as const) : ("stopped" as const)
    );
    const service = await ComputeNodeService.open({
      adapter: runtime,
      arch: "arm64",
      platform: "darwin",
      filePath: join(tempDir, "shell-enable.json"),
      installAuthorization: {
        ...testInstallAuthorization,
        configure,
        inspect: async () => ({
          authorizationStatus: "handed_off" as const,
          status: "ready" as const,
          shellPhase: "ready" as const,
          workActivity: "unknown" as const,
        }),
      },
    });
    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });
    await service.drain();
    configure.mockClear();
    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });
    expect(configure).toHaveBeenCalledWith(
      expect.objectContaining({ enabled: true, operationId: "vmm_install_test" })
    );
    expect(runtime.calls).toEqual(["install", "drain", "enable"]);
  });

  it("closes server admission before exact local drain or removal", async () => {
    const events: string[] = [];
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    runtime.install = async () => {
      events.push("local-install");
      runtime.observation = {
        connector: "ready",
        host: "ready",
        readability: "readable",
        salix: "ready",
      };
    };
    runtime.enable = async () => {
      events.push("local-enable");
    };
    runtime.drain = async () => {
      events.push("local-drain");
      runtime.observation = {
        ...runtime.observation,
        connector: "stopped",
      };
    };
    runtime.remove = async () => {
      events.push("local-remove");
      runtime.observation = {
        ...runtime.observation,
        salix: "revoked",
        registration: "present",
        registrationState: "revoked",
      };
    };
    let productStatus = "processing" as "processing" | "ready" | "stopped" | "removed";
    const authorization = {
      authorize: vi.fn(async () => {
        events.push("server-authorize");
        productStatus = "ready";
        return {
          descriptor: JSON.stringify({ version: 1 }),
          operationId: "vmm-install-order",
          registrationId: "registration-order",
        };
      }),
      configure: vi.fn(async ({ enabled }: { enabled: boolean }) => {
        events.push(enabled ? "server-enable" : "server-disable");
        productStatus = enabled ? "ready" : "stopped";
        return productStatus;
      }),
      observe: vi.fn(async () => productStatus),
      inspect: vi.fn(async () => ({
        authorizationStatus: "handed_off" as const,
        workActivity: "unknown" as const,
        status: productStatus,
      })),
      retry: vi.fn(async () => ({
        descriptor: JSON.stringify({ version: 1 }),
        operationId: "vmm-install-order",
        registrationId: "registration-order",
      })),
      revoke: vi.fn(async () => {
        events.push("server-revoke");
        productStatus = "removed";
        return productStatus;
      }),
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "order.json"),
      installAuthorization: authorization,
      platform: "darwin",
    });

    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });
    await service.drain();
    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });
    await service.remove();

    expect(events).toEqual([
      "server-authorize",
      "local-install",
      "server-disable",
      "local-drain",
      "server-enable",
      "local-enable",
      "server-revoke",
      "local-remove",
    ]);
  });

  it.each(["drain", "remove"] as const)(
    "rejects a stale %s confirmation after rebinding",
    async (action) => {
      const runtime = new FakeRuntime();
      runtime.provisioned = true;
      const authorization = {
        ...testInstallAuthorization,
        observe: vi.fn(async () =>
          runtime.observation.salix === "revoked"
            ? ("removed" as const)
            : ("ready" as const)
        ),
        inspect: vi.fn(async () => ({
          authorizationStatus: "handed_off" as const,
          status:
            runtime.observation.salix === "revoked"
              ? ("removed" as const)
              : ("ready" as const),
          workActivity: "unknown" as const,
        })),
        configure: vi.fn(testInstallAuthorization.configure),
        revoke: vi.fn(testInstallAuthorization.revoke),
        authorize: vi.fn(async ({ workspaceId }: { workspaceId: string }) => ({
          descriptor: JSON.stringify({ version: 1 }),
          operationId: `install_${workspaceId}`,
          registrationId: `registration_${workspaceId}`,
        })),
      };
      const service = await ComputeNodeService.open({
        adapter: runtime,
        arch: "arm64",
        filePath: join(tempDir, "rebinding.json"),
        installAuthorization: authorization,
        platform: "darwin",
      });
      await service.configure({ desiredEnabled: true, workspaceId: "wsp_a" });
      const confirmed = {
        workspaceId: "wsp_a",
        installationId: "install_wsp_a",
        bindingRevision: service.state().bindingRevision!,
      };
      await service.remove();
      await service.configure({ desiredEnabled: true, workspaceId: "wsp_b" });
      const calls = [...runtime.calls];
      authorization.configure.mockClear();
      authorization.revoke.mockClear();
      await expect(service[action](confirmed)).rejects.toThrow("binding changed");
      expect(runtime.calls).toEqual(calls);
      expect(authorization.configure).not.toHaveBeenCalled();
      expect(authorization.revoke).not.toHaveBeenCalled();
      expect(service.state()).toMatchObject({
        desiredEnabled: true,
        bindingWorkspaceId: "wsp_b",
      });
    }
  );

  it("reuses the product request identity after authorization response loss", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const requestIds: string[] = [];
    const authorization = {
      ...testInstallAuthorization,
      authorize: vi.fn(async ({ requestId }: { requestId: string }) => {
        requestIds.push(requestId);
        if (requestIds.length === 1) throw new Error("authorization response lost");
        return {
          descriptor: JSON.stringify({ version: 1 }),
          operationId: "vmm-install-recovered",
          registrationId: "registration-recovered",
        };
      }),
      observe: vi.fn(async () => "ready" as const),
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "auth-loss.json"),
      installAuthorization: authorization,
      platform: "darwin",
    });

    expect(
      await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).toMatchObject({ status: "processing" });
    // Continuation first reads the original request, then retries the same idempotency key.
    await advance(service, 0);

    expect(requestIds).toHaveLength(2);
    expect(requestIds[1]).toBe(requestIds[0]);
    expect(service.state().status).toBe("ready");
  });

  it("checks an unknown exchange-committed result read-only then permits explicit same-operation resume", async () => {
    const filePath = join(tempDir, "exchange.json");
    await writeFile(
      filePath,
      JSON.stringify({
        desiredEnabled: true,
        installOperationId: "vmm-install-exchanged",
        registrationId: "registration-exchanged",
        workspaceId: "wsp_test",
        revision: 3,
        version: 3,
        operation: {
          connectionEpoch: "1",
          kind: "configure",
          leaseGeneration: 0,
          operationId: "vmm-install-exchanged",
          outcome: "unknown",
          requestId: "request-exchanged",
          targetRef: "compute-node/local",
          targetRevision: 1,
        },
      })
    );
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const authorization = {
      ...testInstallAuthorization,
      configure: vi.fn(async () => "processing" as const),
      inspect: vi.fn(async () => ({
        authorizationStatus: "exchange_committed" as const,
        workActivity: "unknown" as const,
        status: "processing" as const,
      })),
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      arch: "arm64",
      filePath,
      installAuthorization: authorization,
      platform: "darwin",
    });

    const checked = await service.refresh();
    expect(checked.issue).toBe("operation_unknown");
    expect(checked.recoveryActions).toContain("continue_enable");
    expect(runtime.calls).not.toContain("resume");
    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });

    expect(runtime.calls).toContain("resume");
    expect(authorization.configure).not.toHaveBeenCalled();
  });

  it("persists the enabled target before the helper side effect and recovers it", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tempDir, "crash.json");
    let persistedAtSideEffect!: {
      desiredEnabled: boolean;
      operation: { outcome: string; kind: string };
    };
    runtime.install = async () => {
      persistedAtSideEffect = JSON.parse(await readFile(filePath, "utf8"));
      runtime.calls.push("install");
      runtime.observation = {
        connector: "ready",
        host: "ready",
        readability: "readable",
        salix: "ready",
      };
      throw new Error("simulated process exit after install");
    };

    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });

    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).rejects.toThrow("simulated process exit");
    expect(persistedAtSideEffect).toMatchObject({
      desiredEnabled: true,
      operation: { kind: "configure", outcome: "pending" },
    });

    // Restore the last durable record as if the client exited at the side
    // effect boundary. A fresh service must recover toward the stored target.
    await writeFile(filePath, JSON.stringify(persistedAtSideEffect));
    const recovered = publishedState((state) => state.status === "ready");
    await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
      onStateChanged: recovered.onStateChanged,
    });
    expect(await recovered.state).toMatchObject({
      desiredEnabled: true,
      status: "ready",
    });
  });

  it("explicitly detaches an inaccessible registration before switching workspace", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const revoke = vi.fn(async () => {
      throw new Error("server unavailable");
    });
    const authorization = { ...testInstallAuthorization, revoke };
    const filePath = join(tempDir, "detach.json");
    const service = await ComputeNodeService.open({
      adapter: runtime,
      arch: "arm64",
      platform: "darwin" as const,
      filePath,
      installAuthorization: authorization,
    });
    await service.configure({ desiredEnabled: true, workspaceId: "old" });
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "new" })
    ).rejects.toThrow("Remove");
    await expect(service.remove()).rejects.toThrow("server unavailable");
    expect(runtime.calls).not.toContain("remove");
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBe("old");
    revoke.mockRejectedValue(new ComputeNodeAuthorizationNotFoundError());
    runtime.removeUnknown = true;
    await expect(service.remove()).rejects.toThrow("Use local VMM management");
    expect(runtime.calls).not.toContain("remove");
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBe("old");
    runtime.removeUnknown = false;
    runtime.observation.registration = "absent";
    expect(await service.remove()).toMatchObject({
      status: "removed",
      problem: "remote_revocation_unconfirmed",
    });
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBeUndefined();
    await service.configure({ desiredEnabled: true, workspaceId: "new" });
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBe("new");
  });

  it("does not settle an unknown remove when the installed host is only stopped", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tempDir, "remove.json");
    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });

    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });
    runtime.removeUnknown = true;
    await expect(service.remove()).rejects.toThrow("timed out");

    const reconciled = publishedState((state) => state.status === "action_required");
    const restarted = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
      onStateChanged: reconciled.onStateChanged,
    });

    expect(await reconciled.state).toMatchObject({
      observed: { connector: "ready", host: "stopped" },
      operation: { kind: "remove", outcome: "unknown" },
      status: "action_required",
    });
    expect(restarted.state().status).not.toBe("removed");
  });

  it("reads independent activity from the authorized installation projection and clears stale activity", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const inspect = vi.fn(async () => ({
      authorizationStatus: "handed_off" as const,
      status: "ready" as const,
      workActivity: "active" as const,
    }));
    const service = await ComputeNodeService.open({
      installAuthorization: { ...testInstallAuthorization, inspect },
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "activity.json"),
      platform: "darwin",
    });
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({
      facets: { workActivity: "active" },
      status: "ready",
    });
    expect(inspect).toHaveBeenCalledWith({
      operationId: "vmm_install_test",
      workspaceId: "wsp_test",
    });
    inspect.mockRejectedValueOnce(new Error("observation unavailable"));
    await expect(service.refresh()).resolves.toMatchObject({
      facets: { workActivity: "unknown" },
      observationFresh: false,
    });
    expect(runtime.calls).not.toContain("drain");
  });

  it("keeps an accepted cloud request unknown when its response body is interrupted", async () => {
    const session = {
      state: () => ({
        phase: "signed_in",
        authority: { authorityInstanceId: "main" },
        generation: 1,
        session: { audience: "https://api.example.test", sessionId: "session" },
      }),
      acquireProductCredential: () => ({
        audience: "https://api.example.test",
        authorityInstanceId: "main",
        generation: 1,
        sessionId: "session",
        signal: new AbortController().signal,
        token: "main-only-token",
      }),
      isCurrentProductCredential: () => true,
      reportUnauthorized: async () => undefined,
    } as never;
    const fetcher = vi.fn(async () => {
      const response = new Response("{}", { status: 200 });
      vi.spyOn(response, "json").mockRejectedValue(
        new TypeError("private response token")
      );
      return response;
    });
    const owner = new ComputeNodeInstallAuthorization(
      session,
      mainCoreRequests(session, fetcher)
    );
    await expect(
      owner.authorize({ requestId: "original-request", workspaceId: "workspace" })
    ).rejects.toMatchObject({
      reason: "outcome_unknown",
      native: { code: "cloud_unavailable" },
    });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("treats an observation the core gave up on as unknown activity without stopping independent work", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const session = {
      state: () => ({
        phase: "signed_in",
        authority: { authorityInstanceId: "authority-1" },
        generation: 1,
        session: {
          audience: "https://api.comma.example",
          sessionId: "session-1",
        },
      }),
    } as never;
    // The core bounds the request on its Clock (core/test/compute-node-operations.test.ts) and answers `timeout`.
    const call = vi.fn(async () => {
      throw Object.assign(new Error("took too long"), { code: "timeout" });
    });
    const authorization = new ComputeNodeInstallAuthorization(
      session,
      () => ({ call }) as never
    );
    const filePath = join(tempDir, "activity-timeout.json");
    runtime.observation = {
      connector: "ready",
      host: "ready",
      readability: "readable",
      salix: "ready",
    };
    await writeFile(
      filePath,
      JSON.stringify({
        version: 3,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "wsp_test",
        installOperationId: "vmm_install_test",
        registrationId: "registration-test",
      })
    );
    const service = await ComputeNodeService.open({
      installAuthorization: {
        ...testInstallAuthorization,
        inspect: (input) => authorization.inspect(input),
      },
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });

    // An unread product status is retried on the continuation timer, not shown as a request for the user.
    await expect(service.refresh()).resolves.toMatchObject({
      status: "processing",
      facets: { workActivity: "unknown" },
    });
    expect(call).toHaveBeenCalled();
    expect(runtime.calls).toEqual([]);
  });

  it("does not wait for runtime observation before returning initial state", async () => {
    let release!: () => void;
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const runtime = new FakeRuntime();
    runtime.observe = async () => {
      await blocked;
      return { ...runtime.observation };
    };

    const opened = ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "prompt.json"),
      platform: "darwin",
    });

    await expect(opened).resolves.toBeInstanceOf(ComputeNodeService);
    release();
  });

  it("reports unsupported and partial failure without losing the error", async () => {
    const runtime = new FakeRuntime();
    const unsupported = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "x64",
      filePath: join(tempDir, "unsupported.json"),
      platform: "darwin",
    });
    expect(unsupported.state().status).toBe("action_required");
    await expect(unsupported.repair()).rejects.toThrow("Apple silicon");

    runtime.failRepair = true;
    const lines: string[] = [];
    const degraded = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "degraded.json"),
      platform: "darwin",
      log: (line) => lines.push(line),
    });
    expect(
      await degraded.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).toMatchObject({ desiredEnabled: true, status: "processing" });
    expect(lines.join("\n")).toContain("bundle verification failed");
  });

  it("does not present repair-only state as an enrolled compute node", async () => {
    const runtime = new FakeRuntime();
    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tempDir, "unenrolled.json"),
      platform: "darwin",
    });

    // The connector is not running, so the node is not ready: Main re-enables it.
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({ status: "processing" });
    expect(service.state()).toMatchObject({
      desiredEnabled: true,
      observed: { readability: "readable", salix: "ready" },
      status: "processing",
    });
  });
});

/** Main's session double, signed in to session-1. */
const signedInSession = () =>
  ({
    state: () => ({
      phase: "signed_in",
      authority: { authorityInstanceId: "authority-1" },
      generation: 1,
      session: { audience: "https://api.comma.example", sessionId: "session-1" },
    }),
  }) as never;

describe("ComputeNodeInstallAuthorization", () => {
  it("asks the core for the session Main holds, and gives the one-time descriptor back", async () => {
    const call = vi.fn(async (_name: string, _params: unknown) => ({
      descriptor: '{"one_time_secret":"ticket-secret"}',
      operationId: "vmm-install-1",
      registrationId: "external-registration-1",
    }));
    const owner = new ComputeNodeInstallAuthorization(
      signedInSession(),
      () => ({ call }) as never
    );
    await expect(
      owner.authorize({ requestId: "request-1", workspaceId: "workspace-1" })
    ).resolves.toEqual({
      descriptor: '{"one_time_secret":"ticket-secret"}',
      operationId: "vmm-install-1",
      registrationId: "external-registration-1",
    });
    expect(call).toHaveBeenCalledWith("computeNode.authorize", {
      requestId: "request-1",
      workspaceId: "workspace-1",
      lease: {
        audience: "https://api.comma.example",
        authorityInstanceId: "authority-1",
        generation: 1,
        sessionId: "session-1",
      },
    });
  });

  it("names an unreachable or unreadable answer, a scoped 404 and a changed session", async () => {
    const failing = (error: Record<string, unknown>) =>
      new ComputeNodeInstallAuthorization(
        signedInSession(),
        () =>
          ({
            call: async () => {
              throw Object.assign(new Error("refused"), error);
            },
          }) as never
      );
    const input = { operationId: "vmm-install-1", workspaceId: "workspace-1" };
    for (const code of ["network", "timeout", "bad_response"])
      await expect(failing({ code }).inspect(input)).rejects.toMatchObject({
        reason: "outcome_unknown",
        native: { code: "cloud_unavailable" },
      });
    await expect(
      failing({ code: "http_404", status: 404 }).revoke(input)
    ).rejects.toBeInstanceOf(ComputeNodeAuthorizationNotFoundError);
    await expect(
      failing({ code: "http_404", status: 404 }).authorize({
        requestId: "request-1",
        workspaceId: "workspace-1",
      })
    ).rejects.toThrow("Compute node authorization failed (404 other).");
    // The server's refusal reason is kept only as a known code, and a 4xx other than 408 and 429 is terminal.
    await expect(
      failing({ code: "terminal_registration", status: 400 }).configure({
        ...input,
        enabled: true,
      })
    ).rejects.toMatchObject({
      message: "Compute node enable failed (400 terminal_registration).",
      reason: "terminal_registration",
      terminal: true,
    });
    await expect(
      failing({ code: "secret_value_from_server", status: 429 }).retry(input)
    ).rejects.toMatchObject({ reason: "other", terminal: false });
    // A concurrent update clears by itself: continuation keeps retrying it.
    await expect(
      failing({ code: "update_in_progress", status: 409 }).configure({
        ...input,
        enabled: true,
      })
    ).rejects.toMatchObject({ reason: "update_in_progress", terminal: false });
    await expect(failing({ code: "session_changed" }).inspect(input)).rejects.toThrow(
      "Compute node status session changed."
    );
  });

  it("makes its requests through a core over HTTP", async () => {
    const fetcher = vi.fn(
      async (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Response(
          JSON.stringify({
            operation: { authorization_status: "handed_off", status: "ready" },
          }),
          { status: 200, headers: { "content-type": "application/json" } }
        )
    ) as unknown as typeof fetch;
    const owner = new ComputeNodeInstallAuthorization(
      signedInSession(),
      mainCoreRequests(signedInSession(), fetcher)
    );
    await expect(
      owner.inspect({ operationId: "vmm-install-1", workspaceId: "workspace-1" })
    ).resolves.toMatchObject({ status: "ready", workActivity: "unknown" });
    expect(String(vi.mocked(fetcher).mock.calls[0]![0])).toBe(
      "https://api.comma.example/v1/comma/workspaces/workspace-1/compute-nodes/agent-vmm/install-operations/vmm-install-1"
    );
  });

  it("keeps the server's failure code of an action-required operation", async () => {
    const fetcher = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            operation: {
              authorization_status: "action_required",
              status: "action_required",
              error_code: "material_handoff_expired",
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } }
        )
    ) as unknown as typeof fetch;
    const owner = new ComputeNodeInstallAuthorization(
      signedInSession(),
      mainCoreRequests(signedInSession(), fetcher)
    );
    await expect(
      owner.inspect({ operationId: "vmm-install-1", workspaceId: "workspace-1" })
    ).resolves.toMatchObject({
      authorizationStatus: "action_required",
      errorCode: "material_handoff_expired",
    });
  });
});

describe("ComputeNodeService expired material handoff", () => {
  let tempDir: string;
  let filePath: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "comma-handoff-expired-"));
    filePath = join(tempDir, "intent.json");
  });

  afterEach(async () => {
    await rm(tempDir, { force: true, recursive: true });
  });

  const expiredIntent = (extra: Record<string, unknown> = {}) =>
    writeFile(
      filePath,
      JSON.stringify({
        version: 3,
        revision: 2,
        desiredEnabled: true,
        workspaceId: "workspace",
        installOperationId: "vmm_install_expired",
        registrationId: "registration-expired",
        operation: {
          connectionEpoch: "1",
          kind: "configure",
          leaseGeneration: 0,
          operationId: "vmm_install_expired",
          outcome: "unknown",
          requestId: "req_original",
          targetRef: "compute-node/local",
          targetRevision: 1,
        },
        ...extra,
      })
    );

  /** The server: the listed operations expired their handoff; every new install becomes ready. */
  function server(expired: Set<string>, errorCode = "material_handoff_expired") {
    let next = 0;
    const authorize = vi.fn(
      async (_input: { requestId: string; workspaceId: string }) => {
        next++;
        return {
          descriptor: JSON.stringify({ version: 1 }),
          operationId: `vmm_install_new_${next}`,
          registrationId: `registration-new-${next}`,
        };
      }
    );
    const inspect = vi.fn(async ({ operationId }: { operationId: string }) =>
      expired.has(operationId)
        ? {
            authorizationStatus: "action_required" as const,
            status: "action_required" as const,
            workActivity: "unknown" as const,
            errorCode,
          }
        : {
            authorizationStatus: "handed_off" as const,
            status: "ready" as const,
            workActivity: "idle" as const,
          }
    );
    return {
      authorize,
      inspect,
      owner: { ...testInstallAuthorization, authorize, inspect },
    };
  }

  const open = (
    owner: ComputeNodeInstallAuthorizationOwner,
    runtime = new FakeRuntime(),
    extra: Partial<Parameters<typeof ComputeNodeService.open>[0]> = {}
  ) =>
    ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: owner,
      ...extra,
    });

  it("starts one new installation with a new request id and archives the expired one", async () => {
    await expiredIntent();
    const { authorize, owner } = server(new Set(["vmm_install_expired"]));
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const service = await open(owner, runtime);
    await advance(service, 0);
    const state = service.state();

    expect(authorize).toHaveBeenCalledTimes(1);
    expect(authorize.mock.calls[0]![0]).toMatchObject({ workspaceId: "workspace" });
    expect(authorize.mock.calls[0]![0].requestId).not.toBe("req_original");
    expect(runtime.calls).toContain("install");
    expect(state).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_new_1",
    });
    const archived = JSON.parse(
      await readFile(
        join(
          `${filePath}.removals`,
          `${Buffer.from("vmm_install_expired").toString("base64url")}.json`
        ),
        "utf8"
      )
    );
    expect(archived).toMatchObject({
      installOperationId: "vmm_install_expired",
      registrationId: "registration-expired",
    });
  });

  it("stops after a second expiry, asks the user to continue, and Continue starts again", async () => {
    await expiredIntent();
    const expired = new Set(["vmm_install_expired", "vmm_install_new_1"]);
    const { authorize, owner } = server(expired);
    const service = await open(owner);
    await advance(service, 0);
    const stopped = await service.refresh();

    expect(authorize).toHaveBeenCalledTimes(1);
    expect(stopped).toMatchObject({
      status: "action_required",
      issue: "enable_incomplete",
      problem: "setup_handoff_expired",
      bindingInstallationId: "vmm_install_new_1",
    });
    expect(stopped.recoveryActions).toContain("continue_enable");

    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(authorize).toHaveBeenCalledTimes(2);
    const requests = authorize.mock.calls.map(([input]) => input.requestId);
    expect(new Set(["req_original", ...requests]).size).toBe(3);
    expect(service.state().bindingInstallationId).toBe("vmm_install_new_2");
  });

  it("does not restart again after a relaunch that already used its restart", async () => {
    await expiredIntent({ handoffRestartUsed: true });
    const { authorize, owner } = server(new Set(["vmm_install_expired"]));
    const service = await open(owner);
    const state = await service.refresh();
    expect(authorize).not.toHaveBeenCalled();
    expect(state).toMatchObject({
      issue: "enable_incomplete",
      problem: "setup_handoff_expired",
      bindingInstallationId: "vmm_install_expired",
    });
  });

  it("reopens exhausted tickets on the same operation, and replaces nothing when disabled or during Host maintenance", async () => {
    await expiredIntent();
    const other = server(new Set(["vmm_install_expired"]), "ticket_retry_exhausted");
    const retry = vi.spyOn(other.owner, "retry");
    const reopened = await open(other.owner);
    await advance(reopened, 0);
    expect(other.authorize).not.toHaveBeenCalled();
    expect(retry).toHaveBeenCalledExactlyOnceWith({
      operationId: "vmm_install_expired",
      workspaceId: "workspace",
    });
    exitProcess();

    await expiredIntent({ desiredEnabled: false });
    const disabled = server(new Set(["vmm_install_expired"]));
    const stopped = await open(disabled.owner);
    await advance(stopped, 60_000);
    expect(disabled.authorize).not.toHaveBeenCalled();
    exitProcess();

    await expiredIntent();
    const maintained = server(new Set(["vmm_install_expired"]));
    const service = await open(maintained.owner, new FakeRuntime(), {
      assertInstallationAllowed: async () => {
        throw new Error("Continue local Host maintenance first.");
      },
    });
    await advance(service, 0);
    // Host maintenance owns the Host: the replacement waits for a later step.
    expect(service.state().status).toBe("processing");
    expect(maintained.authorize).not.toHaveBeenCalled();
  });

  it.each([
    { reason: "authorization_expired" as const, replaced: true },
    { reason: "revoked" as const, replaced: false },
  ])(
    "replaces an installation once when its authorization expired, and never when it was revoked ($reason)",
    async ({ reason, replaced }) => {
      await expiredIntent();
      const { authorize, owner } = server(new Set());
      const revoked = new Set(["vmm_install_expired"]);
      const inspect = vi.fn(async ({ operationId }: { operationId: string }) =>
        revoked.has(operationId)
          ? {
              authorizationStatus: "revoked" as const,
              status: "removed" as const,
              workActivity: "unknown" as const,
              registrationRevocationReason: reason,
            }
          : {
              authorizationStatus: "handed_off" as const,
              status: "ready" as const,
              workActivity: "idle" as const,
            }
      );
      const revoke = vi.fn(async () => "removed" as const);
      const runtime = new FakeRuntime();
      runtime.provisioned = true;
      runtime.observation = {
        ...runtime.observation,
        host: "ready",
        connector: "ready",
        registration: "present",
        registrationState: "enabled",
      };
      const service = await open({ ...owner, inspect, revoke }, runtime);
      await advance(service, 60_000);
      if (!replaced) {
        expect(service.state()).toMatchObject({
          status: "action_required",
          issue: "revoked",
          problem: "registration_revoked",
          recoveryActions: ["finish_remove", "check_status"],
        });
        expect(revoke).not.toHaveBeenCalled();
        expect(authorize).not.toHaveBeenCalled();
        expect(runtime.calls).toEqual([]);
        return;
      }
      // The exact old installation is retired first: server revocation, then the local registration.
      expect(revoke).toHaveBeenCalledExactlyOnceWith({
        operationId: "vmm_install_expired",
        workspaceId: "workspace",
      });
      expect(runtime.calls.slice(0, 2)).toEqual(["remove", "install"]);
      expect(authorize).toHaveBeenCalledOnce();
      expect(authorize.mock.calls[0]![0].requestId).not.toBe("req_original");
      expect(service.state()).toMatchObject({
        status: "ready",
        bindingInstallationId: "vmm_install_new_1",
      });
      // A second expiry in the same enable asks the user; it is not replaced again.
      revoked.add("vmm_install_new_1");
      expect(await service.refresh()).toMatchObject({
        status: "action_required",
        issue: "enable_incomplete",
        recoveryActions: ["continue_enable", "check_status"],
      });
      await advance(service, 60_000);
      expect(authorize).toHaveBeenCalledOnce();
      expect(JSON.parse(await readFile(filePath, "utf8"))).toMatchObject({
        automaticReinstallUsed: true,
      });
    }
  );

  it("logs a failed setup stage with a bounded, redacted message", async () => {
    const lines: string[] = [];
    const runtime = new FakeRuntime();
    runtime.install = async () => {
      throw new Error(
        `lifecycle helper failed: one_time_secret=s3cr3t-value Bearer abc.def token ${"Q".repeat(40)} ${"x ".repeat(600)}`
      );
    };
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: testInstallAuthorization,
      log: (line) => lines.push(line),
    });
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(lines).toHaveLength(1);
    const [line] = lines as [string];
    expect(line).toContain("problem=setup_failed");
    expect(line).toContain("stage=install");
    expect(line).toContain("lifecycle helper failed");
    expect(line.length).toBeLessThan(700);
    expect(line).not.toContain("s3cr3t-value");
    expect(line).not.toContain("abc.def");
    expect(line).not.toContain("Q".repeat(40));
    expect(line).not.toContain("version");
  });
});

describe("ComputeNodeService lost local registration", () => {
  let tempDir: string;
  let filePath: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "comma-registration-lost-"));
    filePath = join(tempDir, "intent.json");
  });

  afterEach(async () => {
    await rm(tempDir, { force: true, recursive: true });
  });

  /** An installation that Main applied and the server handed off. The last enable left its continuation ended. */
  const appliedIntent = (extra: Record<string, unknown> = {}) =>
    writeFile(
      filePath,
      JSON.stringify({
        version: 3,
        revision: 2,
        desiredEnabled: true,
        workspaceId: "workspace",
        installOperationId: "vmm_install_old",
        installAppliedOperationId: "vmm_install_old",
        registrationId: "registration-old",
        operation: {
          connectionEpoch: "1",
          kind: "configure",
          leaseGeneration: 0,
          operationId: "vmm_install_old",
          outcome: "failed",
          requestId: "req_original",
          targetRef: "compute-node/local",
          targetRevision: 1,
        },
        ...extra,
      })
    );

  /** A healthy Host. Each install writes its registration; `lose` removes it, as a Host reset does. */
  function host(registration: "present" | "absent") {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const present = {
      registration: "present" as const,
      registrationState: "enabled" as const,
    };
    runtime.observation = {
      host: "ready",
      readability: "readable",
      ...(registration === "present"
        ? { ...present, connector: "stopped", salix: "unregistered" }
        : { registration: "absent", connector: "absent", salix: "unregistered" }),
    };
    const install = runtime.install.bind(runtime);
    runtime.install = async () => {
      await install();
      runtime.observation = { ...runtime.observation, ...present };
    };
    const lose = () => {
      runtime.observation = {
        host: "ready",
        readability: "readable",
        registration: "absent",
        connector: "absent",
        salix: "unregistered",
      };
    };
    return { runtime, lose };
  }

  /** The server: every operation is handed off; each new install is a new operation. */
  function server(status: "processing" | "ready" = "ready") {
    let next = 0;
    const authorize = vi.fn(
      async (_input: { requestId: string; workspaceId: string }) => {
        next++;
        return {
          descriptor: JSON.stringify({ version: 1 }),
          operationId: `vmm_install_new_${next}`,
          registrationId: `registration-new-${next}`,
        };
      }
    );
    const inspect = vi.fn(async ({ operationId }: { operationId: string }) => ({
      authorizationStatus: "handed_off" as const,
      status: operationId === "vmm_install_old" ? status : ("ready" as const),
      workActivity: "idle" as const,
    }));
    const configure = vi.fn(
      async (_input: { operationId: string; enabled: boolean }) => "ready" as const
    );
    const revoke = vi.fn(
      async (_input: { operationId: string; workspaceId: string }) => "removed" as const
    );
    return {
      authorize,
      inspect,
      configure,
      revoke,
      owner: { ...testInstallAuthorization, authorize, inspect, configure, revoke },
    };
  }

  const open = (
    owner: ComputeNodeInstallAuthorizationOwner,
    runtime: FakeRuntime,
    lines: string[] = []
  ) =>
    ComputeNodeService.open({
      adapter: runtime,
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: owner,
      log: (line) => lines.push(line),
    });

  const saved = async () => JSON.parse(await readFile(filePath, "utf8"));

  it("replaces a reset installation once, without the enable budget, and a later loss uses the budget", async () => {
    // The old continuation ended against the stale installation before the reset was observed.
    await appliedIntent({ continuationExhausted: true });
    const { runtime, lose } = host("absent");
    const cloud = server();
    // The server no longer has the old registration: its revocation answers 404, which retires it too.
    cloud.revoke.mockRejectedValueOnce(new ComputeNodeAuthorizationNotFoundError());
    const service = await open(cloud.owner, runtime);
    await advance(service, 0);

    expect(cloud.revoke).toHaveBeenCalledExactlyOnceWith({
      operationId: "vmm_install_old",
      workspaceId: "workspace",
    });
    // The stale installation is never enabled again; one new installation replaces it with a new request id.
    expect(cloud.configure).not.toHaveBeenCalled();
    expect(cloud.authorize).toHaveBeenCalledOnce();
    expect(cloud.authorize.mock.calls[0]![0].requestId).not.toBe("req_original");
    expect(service.state()).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_new_1",
    });
    expect(await saved()).toMatchObject({
      registrationLossReplaced: "vmm_install_old",
    });
    expect(await saved()).not.toHaveProperty("automaticReinstallUsed");
    expect(await saved()).not.toHaveProperty("continuationExhausted");
    await expect(
      readFile(
        join(
          `${filePath}.removals`,
          `${Buffer.from("vmm_install_old").toString("base64url")}.json`
        ),
        "utf8"
      )
    ).resolves.toContain("registration-old");

    // The new registration disappears without a Host reset: the per-enable budget replaces it once.
    lose();
    await service.refresh();
    await advance(service, 0);
    expect(cloud.authorize).toHaveBeenCalledTimes(2);
    expect(service.state().bindingInstallationId).toBe("vmm_install_new_2");
    expect(await saved()).toMatchObject({ automaticReinstallUsed: true });

    // Again without a reset: Main stops and asks the user instead of a third installation.
    lose();
    expect(await service.refresh()).toMatchObject({
      status: "action_required",
      issue: "enable_incomplete",
      recoveryActions: ["continue_enable", "check_status"],
    });
    await advance(service, 60_000);
    expect(cloud.authorize).toHaveBeenCalledTimes(2);

    // Main's own Host reset makes the loss its consequence: Main replaces the installation at once.
    await service.hostDataReset();
    await advance(service, 0);
    expect(cloud.authorize).toHaveBeenCalledTimes(3);
    expect(service.state()).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_new_3",
    });
  });

  it("replaces a stale registration that the server refuses to enable, without a retry loop", async () => {
    await appliedIntent();
    const { runtime } = host("present");
    const cloud = server("processing");
    cloud.configure.mockImplementation(async ({ operationId }) => {
      if (operationId === "vmm_install_old")
        throw new ComputeNodeCloudRefusalError("enable", 400, "terminal_registration");
      return "ready";
    });
    const lines: string[] = [];
    const service = await open(cloud.owner, runtime, lines);
    await advance(service, 10 * 60_000);

    expect(
      cloud.configure.mock.calls.filter(
        ([input]) => input.operationId === "vmm_install_old"
      )
    ).toHaveLength(1);
    expect(lines).toContainEqual(
      expect.stringMatching(/stage=enable .*\(400 terminal_registration\)/)
    );
    // The local registration is revoked before one new installation replaces the old one.
    expect(cloud.revoke).toHaveBeenCalledExactlyOnceWith({
      operationId: "vmm_install_old",
      workspaceId: "workspace",
    });
    expect(runtime.calls.indexOf("remove")).toBeLessThan(
      runtime.calls.indexOf("install")
    );
    expect(cloud.authorize).toHaveBeenCalledOnce();
    expect(service.state()).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_new_1",
    });
  });

  it("keeps a manager revocation observed after an enable refusal from replacing the installation", async () => {
    await appliedIntent();
    const { runtime } = host("present");
    const cloud = server("processing");
    let revoked = false;
    cloud.configure.mockImplementation(async () => {
      revoked = true;
      throw new ComputeNodeCloudRefusalError("enable", 400, "terminal_registration");
    });
    const owner: ComputeNodeInstallAuthorizationOwner = {
      ...cloud.owner,
      inspect: async (input) =>
        revoked
          ? {
              authorizationStatus: "revoked",
              registrationRevocationReason: "revoked",
              status: "action_required",
              workActivity: "idle",
            }
          : cloud.inspect(input),
    };
    const service = await open(owner, runtime);
    await advance(service, 10 * 60_000);

    expect(cloud.configure).toHaveBeenCalledOnce();
    expect(cloud.authorize).not.toHaveBeenCalled();
    expect(cloud.revoke).not.toHaveBeenCalled();
    expect(runtime.calls).not.toContain("remove");
    expect(service.state()).toMatchObject({
      status: "action_required",
      issue: "revoked",
    });
  });

  /** The server reports the old installation as revoked with `reason`; a new installation is handed off. */
  const revokedServer = (reason: "revoked" | "authorization_expired" | undefined) => {
    const cloud = server();
    const inspect = vi.fn(async ({ operationId }: { operationId: string }) =>
      operationId === "vmm_install_old"
        ? {
            authorizationStatus: "revoked" as const,
            status: "removed" as const,
            workActivity: "unknown" as const,
            ...(reason ? { registrationRevocationReason: reason } : {}),
          }
        : {
            authorizationStatus: "handed_off" as const,
            status: "ready" as const,
            workActivity: "idle" as const,
          }
    );
    return { ...cloud, owner: { ...cloud.owner, inspect } };
  };

  it.each([{ reason: "revoked" as const }, { reason: undefined }])(
    "replaces an installation that Main's own reset made stale, whatever revocation reason the server records ($reason)",
    async ({ reason }) => {
      await appliedIntent({
        automaticReinstallUsed: true,
        continuationExhausted: true,
      });
      const { runtime } = host("absent");
      const cloud = revokedServer(reason);
      cloud.revoke.mockRejectedValueOnce(
        new ComputeNodeCloudRefusalError("revoke", 400, "terminal_registration")
      );
      const service = await open(cloud.owner, runtime);
      await advance(service, 60_000);
      // Before Main's reset: the server's revocation needs the user.
      expect(cloud.authorize).not.toHaveBeenCalled();
      expect(service.state().status).toBe("action_required");

      await service.hostDataReset();
      await advance(service, 0);
      expect(cloud.revoke).toHaveBeenCalledExactlyOnceWith({
        operationId: "vmm_install_old",
        workspaceId: "workspace",
      });
      expect(cloud.authorize).toHaveBeenCalledOnce();
      expect(service.state()).toMatchObject({
        status: "ready",
        bindingInstallationId: "vmm_install_new_1",
      });
      expect(service.state().problem).toBeUndefined();
      expect(await saved()).not.toHaveProperty("hostResetInstallation");
    }
  );

  it("keeps an explicit manager revocation for the user's removal when Main did not reset, and clears it once removed", async () => {
    await appliedIntent();
    const { runtime } = host("present");
    const cloud = revokedServer("revoked");
    const service = await open(cloud.owner, runtime);
    await advance(service, 10 * 60_000);
    expect(service.state()).toMatchObject({
      status: "action_required",
      issue: "revoked",
      problem: "registration_revoked",
      recoveryActions: ["finish_remove", "check_status"],
    });
    // An explicit enable does not replace a manager's revocation.
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow();
    expect(cloud.revoke).not.toHaveBeenCalled();
    expect(cloud.authorize).not.toHaveBeenCalled();
    expect(service.state().problem).toBe("registration_revoked");

    // The user removes it: the node reads as removed, without the earlier revoked result, also after a refresh.
    const removed = await service.remove();
    expect(removed).toMatchObject({
      status: "removed",
      desiredEnabled: false,
      remoteRevocationConfirmed: true,
    });
    expect(removed.issue).toBeUndefined();
    expect(removed.problem).toBeUndefined();
    const refreshed = await service.refresh();
    expect(refreshed.status).toBe("removed");
    expect(refreshed.issue).toBeUndefined();
    expect(refreshed.problem).toBeUndefined();
  });

  it("names a revocation without a reason as an invalid connection, and one Enable again replaces it", async () => {
    await appliedIntent();
    const { runtime } = host("present");
    const cloud = revokedServer(undefined);
    const service = await open(cloud.owner, runtime);
    await advance(service, 10 * 60_000);
    // Main does not replace it by itself.
    expect(cloud.authorize).not.toHaveBeenCalled();
    expect(cloud.revoke).not.toHaveBeenCalled();
    expect(service.state()).toMatchObject({
      status: "action_required",
      issue: "needs_attention",
      problem: "registration_invalid",
      recoveryActions: ["continue_enable", "check_status"],
    });

    const state = await service.configure({
      desiredEnabled: true,
      workspaceId: "workspace",
    });
    // One call retires the exact old installation and starts a new one.
    expect(cloud.revoke).toHaveBeenCalledExactlyOnceWith({
      operationId: "vmm_install_old",
      workspaceId: "workspace",
    });
    expect(runtime.calls.indexOf("remove")).toBeLessThan(
      runtime.calls.indexOf("install")
    );
    expect(cloud.authorize).toHaveBeenCalledOnce();
    expect(state).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_new_1",
    });
    expect(state.problem).toBeUndefined();
  });

  it.each([{ local: "absent" as const }, { local: "present" as const }])(
    "names an unreachable expired installation as an invalid connection, not a manager removal (local $local)",
    async ({ local }) => {
      await appliedIntent();
      const { runtime } = host(local);
      const cloud = revokedServer("authorization_expired");
      // This account can no longer reach the old installation: its revocation answers a scoped 404.
      cloud.revoke.mockRejectedValue(new ComputeNodeAuthorizationNotFoundError());
      const service = await open(cloud.owner, runtime);
      await advance(service, 10 * 60_000);
      expect(cloud.authorize).not.toHaveBeenCalled();
      expect(service.state()).toMatchObject({
        status: "action_required",
        issue: "needs_attention",
        problem: "registration_invalid",
        recoveryActions: ["continue_enable", "check_status"],
      });

      const enabled = service.configure({
        desiredEnabled: true,
        workspaceId: "workspace",
      });
      if (local === "present") {
        // A scoped 404 never authorizes removing a present local registration.
        await enabled.catch(() => undefined);
        await advance(service, 10 * 60_000);
        expect(runtime.calls).not.toContain("remove");
        expect(service.state().problem).toBe("registration_invalid");
        expect(cloud.authorize).not.toHaveBeenCalled();
        return;
      }
      // Enable again detaches the unreachable old installation and starts a new one in one call.
      expect(await enabled).toMatchObject({
        status: "ready",
        bindingInstallationId: "vmm_install_new_1",
      });
      expect(cloud.authorize).toHaveBeenCalledOnce();
      expect(runtime.calls).not.toContain("remove");
    }
  );

  it("retries an enable that a concurrent update refused, then succeeds on the same installation", async () => {
    await appliedIntent();
    const { runtime } = host("present");
    const cloud = server("processing");
    let enabled = false;
    cloud.configure
      .mockRejectedValueOnce(
        new ComputeNodeCloudRefusalError("enable", 409, "update_in_progress")
      )
      .mockImplementation(async () => {
        enabled = true;
        return "ready";
      });
    cloud.inspect.mockImplementation(async () => ({
      authorizationStatus: "handed_off" as const,
      status: enabled ? ("ready" as const) : ("processing" as const),
      workActivity: "idle" as const,
    }));
    const service = await open(cloud.owner, runtime);
    await advance(service, 60_000);

    expect(cloud.configure).toHaveBeenCalledTimes(2);
    expect(cloud.authorize).not.toHaveBeenCalled();
    expect(cloud.revoke).not.toHaveBeenCalled();
    expect(service.state()).toMatchObject({
      status: "ready",
      bindingInstallationId: "vmm_install_old",
    });
  });

  it("asks the user once for another terminal refusal instead of retrying it", async () => {
    await appliedIntent();
    const { runtime } = host("present");
    const cloud = server("processing");
    cloud.configure.mockRejectedValue(
      new ComputeNodeCloudRefusalError("enable", 400, "installation_not_handed_off")
    );
    const service = await open(cloud.owner, runtime);
    await advance(service, 10 * 60_000);

    expect(cloud.configure).toHaveBeenCalledOnce();
    expect(cloud.authorize).not.toHaveBeenCalled();
    expect(service.state()).toMatchObject({
      status: "action_required",
      problem: "setup_blocked",
      issue: "needs_attention",
      recoveryActions: ["continue_enable"],
    });
  });
});

describe("ComputeNodeService automatic continuation", () => {
  let tempDir: string;
  let filePath: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "comma-continuation-"));
    filePath = join(tempDir, "intent.json");
  });

  afterEach(async () => {
    await rm(tempDir, { force: true, recursive: true });
  });

  const enabledIntent = (extra: Record<string, unknown> = {}) =>
    writeFile(
      filePath,
      JSON.stringify({
        version: 4,
        revision: 2,
        desiredEnabled: true,
        workspaceId: "workspace",
        installOperationId: "vmm_install_test",
        installAppliedOperationId: "vmm_install_test",
        registrationId: "registration-test",
        operation: {
          connectionEpoch: "1",
          kind: "configure",
          leaseGeneration: 0,
          operationId: "vmm_install_test",
          outcome: "succeeded",
          requestId: "req_original",
          targetRef: "compute-node/local",
          targetRevision: 1,
        },
        ...extra,
      })
    );

  const open = (extra: Partial<Parameters<typeof ComputeNodeService.open>[0]> = {}) =>
    ComputeNodeService.open({
      adapter: new FakeRuntime(),
      filePath,
      platform: "darwin",
      arch: "arm64",
      installAuthorization: testInstallAuthorization,
      ...extra,
    });

  it.each([
    { activity: "idle" as const, updated: true },
    { activity: "active" as const, updated: false },
  ])(
    "updates a Host without the maintenance protocol only when the server reports no running work ($activity)",
    async ({ activity, updated }) => {
      await enabledIntent();
      let compatible = false;
      const updateHost = vi.fn(async () => {
        compatible = true;
      });
      const runtime = new FakeRuntime();
      runtime.provisioned = true;
      runtime.observation = {
        ...runtime.observation,
        host: "ready",
        connector: "stopped",
      };
      const service = await open({
        adapter: runtime,
        updateHost,
        assertInstallationAllowed: async () => {
          if (!compatible)
            throw new HostMaintenanceIncompatibleError(new Error("old helper"));
        },
        installAuthorization: {
          ...testInstallAuthorization,
          inspect: vi.fn(async () => ({
            authorizationStatus: "handed_off" as const,
            status: "processing" as const,
            workActivity: activity,
          })),
        },
      });
      await advance(service, 60_000);
      if (updated) {
        expect(updateHost).toHaveBeenCalledOnce();
        expect(runtime.calls).toContain("enable");
        return;
      }
      expect(updateHost).not.toHaveBeenCalled();
      expect(runtime.calls).toEqual([]);
      expect(service.state()).toMatchObject({
        status: "action_required",
        issue: "host_update_required",
        problem: "host_update_interrupts_work",
        recoveryActions: ["update_host"],
      });
      expect(armed()).toHaveLength(0);
    }
  );

  it("does not update to a target older than this Mac's data, and offers the confirmed reinstall", async () => {
    const updateHost = vi.fn(async () => {
      throw new HostTargetOlderThanDataError();
    });
    const authorize = vi.fn(testInstallAuthorization.authorize);
    const service = await open({
      updateHost,
      assertInstallationAllowed: async () => {
        throw new HostMaintenanceIncompatibleError(new Error("old helper"));
      },
      installAuthorization: { ...testInstallAuthorization, authorize },
    });
    // No installation exists yet, so no work can run on it: the update is allowed, and refused by data.
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    await advance(service, 60_000);
    expect(updateHost).toHaveBeenCalledOnce();
    expect(authorize).not.toHaveBeenCalled();
    expect(service.state()).toMatchObject({
      status: "action_required",
      problem: "target_older_than_data",
      recoveryActions: ["reinstall_reset"],
    });
    expect(armed()).toHaveLength(0);
  });

  it("lets only the user interrupt running work to recover stuck Host maintenance", async () => {
    await enabledIntent();
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    runtime.observation = {
      ...runtime.observation,
      host: "ready",
      connector: "stopped",
    };
    const reported: boolean[] = [];
    const resumeMaintenance = vi.fn(async (workActive: () => boolean) => {
      reported.push(workActive());
      if (workActive()) throw new HostRecoveryInterruptsWorkError();
      return false;
    });
    const service = await open({
      adapter: runtime,
      resumeMaintenance,
      assertInstallationAllowed: async () => {
        throw new Error("Continue local Host maintenance first.");
      },
      installAuthorization: {
        ...testInstallAuthorization,
        inspect: vi.fn(async () => ({
          authorizationStatus: "handed_off" as const,
          status: "processing" as const,
          workActivity: "active" as const,
        })),
      },
    });
    await advance(service, 60_000);
    expect(reported).toContain(true);
    expect(service.state()).toMatchObject({
      status: "action_required",
      issue: "host_update_required",
      problem: "host_update_interrupts_work",
      recoveryActions: ["update_host"],
    });
  });

  it("stops before installation when the Host preflight finds too little disk space", async () => {
    const authorize = vi.fn(testInstallAuthorization.authorize);
    const runtime = new FakeRuntime();
    const service = await open({
      adapter: runtime,
      preparation: {
        state: () => ({
          source: "download",
          location: "https://example.test/Host.zip",
          instance: "shared",
          phase: "failed",
        }),
        ensure: async () => {
          throw new HostPreflightError(80 * 1024 ** 3, 10 * 1024 ** 3);
        },
        rebuild: async () => {},
      },
      installAuthorization: { ...testInstallAuthorization, authorize },
    });
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow("80 GB");
    expect(service.state()).toMatchObject({
      status: "action_required",
      issue: "insufficient_disk",
      problem: "insufficient_disk",
      diskRequirement: {
        requiredBytes: 80 * 1024 ** 3,
        availableBytes: 10 * 1024 ** 3,
      },
    });
    expect(authorize).not.toHaveBeenCalled();
    expect(runtime.calls).toEqual([]);
    expect(armed()).toHaveLength(0);
  });

  it.each([
    {
      reason: "managed trust stage=anchor_time reason=not_yet_valid",
      problem: "clock_skew",
    },
    {
      reason: "managed trust stage=membership_time reason=expired",
      problem: "clock_skew",
    },
    {
      reason: "managed trust stage=identity reason=subject_mismatch",
      problem: "identity_mismatch",
    },
  ])("names the Host's bounded trust reason $problem", async ({ reason, problem }) => {
    const runtime = new FakeRuntime();
    runtime.install = async () => {
      throw new ComputeNodeCommandError(reason, "command_failed");
    };
    const service = await open({ adapter: runtime });
    expect(
      await service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).toMatchObject({ status: "processing", problem });
  });

  it("reads unknown fields, keeps a newer record read-only, and resets an unreadable one", async () => {
    await enabledIntent({ futureField: { any: true } });
    const known = await open();
    await settled(known);
    expect(known.state()).toMatchObject({ bindingInstallationId: "vmm_install_test" });
    exitProcess();

    await enabledIntent({ version: 99 });
    const before = await readFile(filePath, "utf8");
    const newer = await open();
    await settled(newer);
    expect(newer.state().bindingInstallationId).toBe("vmm_install_test");
    await expect(
      newer.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow("newer Comma");
    expect(await readFile(filePath, "utf8")).toBe(before);
    expect(armed()).toHaveLength(0);
    exitProcess();

    await writeFile(filePath, "{ broken");
    const broken = await open();
    expect(broken.state()).toMatchObject({
      issue: "local_record_unreadable",
      recoveryActions: ["reset_local_record"],
    });
    const reset = await broken.resetLocalRecord();
    expect(reset).toMatchObject({ status: "not_set", desiredEnabled: false });
    const archived = (await readdir(tempDir)).filter((name) =>
      name.startsWith("intent.json.unreadable-")
    );
    expect(archived).toHaveLength(1);
    expect(await readFile(join(tempDir, archived[0]!), "utf8")).toBe("{ broken");
  });

  it("never runs a continuation step armed under an earlier Session generation", async () => {
    const authorize = vi.fn(async () => {
      throw new Error("Workspace service unavailable.");
    });
    const service = new AccountComputeNodeService(
      {
        adapter: new FakeRuntime(),
        filePath,
        platform: "darwin",
        arch: "arm64",
        installAuthorization: { ...testInstallAuthorization, authorize },
      },
      accountSession("A", 1)
    );
    expect(
      await service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).toMatchObject({ status: "processing" });
    expect(authorize).toHaveBeenCalledTimes(1);
    const stale = armed();
    service.sessionChanged(accountSession("B", 2));
    for (const timer of stale) timer.run();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(authorize).toHaveBeenCalledTimes(1);
  });
});
