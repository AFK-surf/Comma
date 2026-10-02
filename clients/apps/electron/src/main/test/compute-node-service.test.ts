import { createServer } from "node:http";
import { AccountComputeNodeService } from "../modules/compute-node/account-service";
import { signedInSessionSnapshotSchema } from "@comma/session-contract";
import { ComputeNodeAuthorizationNotFoundError } from "../modules/compute-node/install-authorization";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { LocalHostMaintenance } from "../modules/compute-node/host-maintenance";
import {
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "../modules/compute-node/host-preparation";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi } from "vitest";
import {
  AgentVMMCommandAdapter,
  ComputeNodeCommandError,
  ComputeNodeInstallAuthorization,
  ComputeNodeService,
  runCommand,
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
  initializeWorkload: vi.fn(async () => {}),
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

describe("ComputeNodeService", () => {
  it("closes only the confirmed unfinished request before a new connection and never removes local resources", async () => {
    const runtime = new FakeRuntime();
    runtime.failRepair = true;
    const filePath = join(tmpdir(), `comma-abandon-${crypto.randomUUID()}.json`);
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
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow("bundle verification failed");
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
    const filePath = join(
      tmpdir(),
      `comma-late-authorization-${crypto.randomUUID()}.json`
    );
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
      const filePath = join(
        tmpdir(),
        `comma-corrupt-intent-${crypto.randomUUID()}.json`
      );
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
    const filePath = join(tmpdir(), `comma-fence-${crypto.randomUUID()}.json`);
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
    const filePath = join(tmpdir(), `comma-lost-request-${crypto.randomUUID()}.json`);
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
      installAuthorization: new ComputeNodeInstallAuthorization(session, fetcher),
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
    const filePath = join(tmpdir(), `comma-http-late-${crypto.randomUUID()}.json`);
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
      installAuthorization: new ComputeNodeInstallAuthorization(session),
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
      filePath: join(tmpdir(), `comma-revision-${crypto.randomUUID()}.json`),
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
        filePath: join(tmpdir(), `comma-account-${crypto.randomUUID()}.json`),
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
      const filePath = join(tmpdir(), `comma-absent-${crypto.randomUUID()}.json`);
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
    const filePath = join(tmpdir(), `comma-unreadable-${crypto.randomUUID()}.json`);
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
    const filePath = join(tmpdir(), `comma-revocation-${crypto.randomUUID()}.json`);
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
    const filePath = join(tmpdir(), `comma-read-${Date.now()}.json`);
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
    expect(state.issue).toBe("connection");
    expect(state.status).toBe("action_required");
    vi.clearAllMocks();
  });

  it("does not create or retry a workload when node readiness times out", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const initializeWorkload = vi.fn(async () => {});
    const service = await ComputeNodeService.open({
      adapter: runtime,
      initializationWaitMs: 0,
      filePath: join(tmpdir(), `comma-init-timeout-${Date.now()}.json`),
      platform: "darwin",
      arch: "arm64",
      installAuthorization: {
        ...testInstallAuthorization,
        observe: vi.fn(async () => "processing" as const),
        initializeWorkload,
      },
    });
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow("Check the node connection");
    expect(initializeWorkload).not.toHaveBeenCalled();
    expect(service.state().status).toBe("action_required");
    vi.clearAllMocks();
  });

  it("initializes once after enable and exposes failure for explicit retry", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const initializeWorkload = vi
      .fn()
      .mockRejectedValueOnce(new Error("initialization failed"))
      .mockResolvedValue(undefined);
    const service = await ComputeNodeService.open({
      adapter: runtime,
      filePath: join(tmpdir(), `comma-init-${Date.now()}.json`),
      platform: "darwin",
      arch: "arm64",
      installAuthorization: { ...testInstallAuthorization, initializeWorkload },
    });
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow("initialization failed");
    expect(initializeWorkload).toHaveBeenCalledTimes(1);
    expect(service.state()).toMatchObject({
      status: "action_required",
      issue: "shell_initialization_pending",
      recoveryActions: ["continue_shell", "check_status"],
    });
    runtime.calls = [];
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(initializeWorkload).toHaveBeenCalledTimes(2);
    expect(runtime.calls).not.toContain("enable");
    expect(runtime.calls).not.toContain("install");
    expect(runtime.calls).not.toContain("resume");
    expect(initializeWorkload).toHaveBeenLastCalledWith({
      operationId: "vmm_install_test",
      workspaceId: "workspace",
    });
    await service.configure({ desiredEnabled: false, workspaceId: "workspace" });
    expect(initializeWorkload).toHaveBeenCalledTimes(2);
    vi.clearAllMocks();
  });

  it("prepares Host before issuing enrollment and requires explicit retry after failure or restart", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const authorization = {
      ...testInstallAuthorization,
      authorize: vi.fn(testInstallAuthorization.authorize),
    };
    let unavailable = true;
    const preparation = {
      state: () => ({
        source: "download" as const,
        location: "https://example.test/Host.zip",
        instance: "shared",
        phase: "idle" as const,
      }),
      ensure: vi.fn(async () => {
        if (unavailable) throw new Error("download unavailable");
        expect(authorization.authorize).not.toHaveBeenCalled();
      }),
      rebuild: vi.fn(async () => {}),
    };
    const filePath = join(tmpdir(), `comma-preparation-${Date.now()}.json`);
    const options = {
      adapter: runtime,
      preparation,
      filePath,
      installAuthorization: authorization,
      platform: "darwin" as const,
      arch: "arm64",
    };
    let service = await ComputeNodeService.open(options);
    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).rejects.toThrow("download unavailable");
    expect(runtime.calls).toEqual([]);
    expect(authorization.authorize).not.toHaveBeenCalled();
    service = await ComputeNodeService.open(options);
    expect(preparation.ensure).toHaveBeenCalledTimes(1);
    unavailable = false;
    expect(
      await service.configure({ desiredEnabled: true, workspaceId: "workspace" })
    ).toMatchObject({ status: "ready" });
    expect(authorization.authorize).toHaveBeenCalledOnce();
    expect(runtime.calls).toEqual(["install"]);
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

  it("bounds a hung lifecycle helper", async () => {
    await expect(
      runCommand(process.execPath, ["-e", "setInterval(() => {}, 1000)"], undefined, 50)
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
      filePath: join(tmpdir(), `.compute-node-unknown-${crypto.randomUUID()}.json`),
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
    const filePath = join(tmpdir(), `.compute-node-${crypto.randomUUID()}.json`);
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

    const restarted = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });
    await vi.waitFor(() =>
      expect(restarted.state()).toMatchObject({ desiredEnabled: true, status: "ready" })
    );
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
      initializeWorkload: vi.fn(async () => {}),
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
      filePath: join(tmpdir(), `.compute-node-order-${crypto.randomUUID()}.json`),
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
        filePath: join(tmpdir(), `.compute-node-fence-${crypto.randomUUID()}.json`),
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
      filePath: join(tmpdir(), `.compute-node-auth-loss-${crypto.randomUUID()}.json`),
      installAuthorization: authorization,
      platform: "darwin",
    });

    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).rejects.toThrow("authorization response lost");
    await service.configure({ desiredEnabled: true, workspaceId: "wsp_test" });

    expect(requestIds).toHaveLength(2);
    expect(requestIds[1]).toBe(requestIds[0]);
  });

  it("checks an unknown exchange-committed result read-only then permits explicit same-operation resume", async () => {
    const filePath = join(
      tmpdir(),
      `.compute-node-exchange-${crypto.randomUUID()}.json`
    );
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
    const filePath = join(tmpdir(), `.compute-node-crash-${crypto.randomUUID()}.json`);
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
    const restarted = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });
    await vi.waitFor(() =>
      expect(restarted.state()).toMatchObject({ desiredEnabled: true, status: "ready" })
    );
  });

  it("explicitly detaches an inaccessible registration before switching workspace", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const revoke = vi.fn(async () => {
      throw new Error("server unavailable");
    });
    const authorization = { ...testInstallAuthorization, revoke };
    const filePath = join(tmpdir(), `.compute-node-detach-${crypto.randomUUID()}.json`);
    const service = await ComputeNodeService.open({
      adapter: runtime,
      arch: "arm64",
      platform: "darwin",
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
      problem: expect.stringContaining("remote revocation is not confirmed"),
    });
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBeUndefined();
    await service.configure({ desiredEnabled: true, workspaceId: "new" });
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBe("new");
  });

  it("does not settle an unknown remove when the installed host is only stopped", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const filePath = join(tmpdir(), `.compute-node-remove-${crypto.randomUUID()}.json`);
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

    const restarted = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath,
      platform: "darwin",
    });

    await vi.waitFor(() =>
      expect(restarted.state()).toMatchObject({
        observed: { connector: "ready", host: "stopped" },
        operation: { kind: "remove", outcome: "unknown" },
        status: "action_required",
      })
    );
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
      filePath: join(tmpdir(), `.compute-node-activity-${crypto.randomUUID()}.json`),
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

  it("bounds a stalled product observation without stopping independent work", async () => {
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
      acquireProductCredential: vi.fn(() => ({
        audience: "https://api.comma.example",
        authorityInstanceId: "authority-1",
        generation: 1,
        sessionId: "session-1",
        signal: new AbortController().signal,
        token: "session-token",
      })),
      isCurrentProductCredential: vi.fn(() => true),
      reportUnauthorized: vi.fn(async () => undefined),
    } as never;
    const fetcher = vi.fn(
      (_input: RequestInfo | URL, init?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("The operation was aborted.", "AbortError")),
            { once: true }
          );
        })
    ) as unknown as typeof fetch;
    const authorization = new ComputeNodeInstallAuthorization(session, fetcher, 10);
    const filePath = join(
      tmpdir(),
      `.compute-node-activity-timeout-${crypto.randomUUID()}.json`
    );
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

    await expect(service.refresh()).resolves.toMatchObject({
      status: "action_required",
      facets: { workActivity: "unknown" },
    });
    expect(fetcher).toHaveBeenCalled();
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
      filePath: join(tmpdir(), `.prompt-${crypto.randomUUID()}.json`),
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
      filePath: join(tmpdir(), `.unsupported-${crypto.randomUUID()}.json`),
      platform: "darwin",
    });
    expect(unsupported.state().status).toBe("action_required");
    await expect(unsupported.repair()).rejects.toThrow("Apple silicon");

    runtime.failRepair = true;
    const degraded = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tmpdir(), `.degraded-${crypto.randomUUID()}.json`),
      platform: "darwin",
    });
    await expect(
      degraded.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).rejects.toThrow("bundle verification failed");
    expect(degraded.state()).toMatchObject({
      desiredEnabled: true,
      problem: "bundle verification failed",
      status: "action_required",
    });
  });

  it("does not present repair-only state as an enrolled compute node", async () => {
    const runtime = new FakeRuntime();
    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tmpdir(), `.unenrolled-${crypto.randomUUID()}.json`),
      platform: "darwin",
    });

    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({ status: "action_required" });
    expect(service.state()).toMatchObject({
      desiredEnabled: true,
      observed: { readability: "readable", salix: "ready" },
      status: "action_required",
    });
  });
});

describe("ComputeNodeInstallAuthorization", () => {
  it("uses the Main-owned bearer and exact server registration identity", async () => {
    const reportUnauthorized = vi.fn(async () => undefined);
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
      acquireProductCredential: vi.fn(() => ({
        audience: "https://api.comma.example",
        authorityInstanceId: "authority-1",
        generation: 1,
        sessionId: "session-1",
        signal: new AbortController().signal,
        token: "main-only-token",
      })),
      isCurrentProductCredential: vi.fn(() => true),
      reportUnauthorized,
    } as never;
    const fetcher = vi.fn(
      async (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Response(
          JSON.stringify({
            descriptor: {
              exchange_url:
                "https://api.comma.example/v1/compute/agent-vmm/install-operations/exchange",
              expires_at: "2026-08-25T00:00:00Z",
              one_time_secret: "ticket-secret",
              operation_id: "vmm-install-1",
              version: 1,
            },
            operation: {
              id: "vmm-install-1",
              registration_id: "external-registration-1",
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } }
        )
    ) as unknown as typeof fetch;
    const owner = new ComputeNodeInstallAuthorization(session, fetcher);

    await expect(
      owner.authorize({
        requestId: "request-1",
        workspaceId: "workspace-1",
      })
    ).resolves.toMatchObject({
      operationId: "vmm-install-1",
      registrationId: "external-registration-1",
    });

    const [url, init] = vi.mocked(fetcher).mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api.comma.example/v1/comma/workspaces/workspace-1/compute-nodes/agent-vmm/install-operations"
    );
    expect(init?.headers).toMatchObject({
      authorization: "Bearer main-only-token",
      "idempotency-key": "request-1",
    });
    expect(init?.body).toBe(JSON.stringify({}));

    vi.mocked(fetcher).mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          operation: { authorization_status: "handed_off", status: "ready" },
        }),
        { status: 200 }
      )
    );
    await owner.initializeWorkload({
      operationId: "vmm-install-1",
      workspaceId: "workspace-1",
    });
    const [initializeUrl, initializeRequest] = vi.mocked(fetcher).mock.calls[1]!;
    expect(String(initializeUrl)).toBe(
      "https://api.comma.example/v1/comma/workspaces/workspace-1/compute-nodes/agent-vmm/install-operations/vmm-install-1/initialize-workload"
    );
    expect(initializeRequest?.method).toBe("POST");
    expect(initializeRequest?.headers).toMatchObject({
      authorization: "Bearer main-only-token",
    });
    const input = { operationId: "vmm-install-1", workspaceId: "workspace-1" };
    for (const [field, expected] of [
      [undefined, "unknown"],
      ["active", "active"],
    ] as const) {
      vi.mocked(fetcher).mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            operation: {
              authorization_status: "handed_off",
              status: "ready",
              work_activity: field,
            },
          }),
          { status: 200 }
        )
      );
      await expect(owner.inspect(input)).resolves.toMatchObject({
        status: "ready",
        workActivity: expected,
      });
    }
    expect(reportUnauthorized).not.toHaveBeenCalled();
    vi.mocked(fetcher).mockResolvedValueOnce(new Response("{}", { status: 401 }));
    await expect(owner.inspect(input)).rejects.toThrow("401");
    expect(reportUnauthorized).toHaveBeenCalledOnce();
  });
});
