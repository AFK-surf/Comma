import { ComputeNodeAuthorizationNotFoundError } from "../modules/compute-node/install-authorization";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi } from "vitest";
import {
  AgentVMMCommandAdapter,
  ComputeNodeInstallAuthorization,
  ComputeWorkloadActivityOwner,
  ComputeNodeService,
  runCommand,
  type ComputeNodeWorkloadObservation,
  type ComputeNodeWorkloadObservationOwner,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeRuntimeObservation,
} from "../modules/compute-node";

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
    this.observation = { ...this.observation, connector: "stopped", host: "stopped" };
  }
  async remove() {
    this.calls.push("remove");
    if (this.removeUnknown) {
      this.observation = {
        ...this.observation,
        connector: "ready",
        host: "stopped",
      };
      throw new Error("Agent VMM command timed out after 15000ms.");
    }
    this.observation = {
      ...this.observation,
      connector: "absent",
      host: "absent",
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
    expect(service.state().status).toBe("action_required");
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(initializeWorkload).toHaveBeenCalledTimes(2);
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

  it("does not infer Salix readiness from a loaded connector process", async () => {
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", async () =>
      JSON.stringify({
        connectorInstalled: true,
        connectorLoaded: true,
        hostInstalled: true,
        hostLoaded: true,
        salixReady: false,
        salixRevoked: false,
      })
    );

    await expect(adapter.observe()).resolves.toEqual({
      connector: "ready",
      host: "stopped",
      readability: "readable",
      salix: "unregistered",
    });
  });

  it("does not infer readiness from the legacy helper facts shape", async () => {
    const adapter = new AgentVMMCommandAdapter("/unused/lifecycle", async () =>
      JSON.stringify({
        connectorInstalled: true,
        connectorLoaded: true,
        hostInstalled: true,
        hostLoaded: true,
        salixReady: true,
        salixRevoked: false,
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
      throw new Error("Agent VMM command timed out after 15000ms.");
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
        host: "stopped",
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
      runtime.observation = { ...runtime.observation, salix: "revoked" };
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
      const confirmed = { workspaceId: "wsp_a", installationId: "install_wsp_a" };
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

  it("resumes exchange-committed installation from its exact durable operation", async () => {
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
          outcome: "pending",
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
    await expect(service.remove()).rejects.toThrow("timed out");
    expect(JSON.parse(await readFile(filePath, "utf8")).workspaceId).toBe("old");
    runtime.removeUnknown = false;
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

  it("takes work activity from the independent Workload observation owner", async () => {
    const runtime = new FakeRuntime();
    runtime.provisioned = true;
    const workloadObservation: ComputeNodeWorkloadObservationOwner = {
      observe: vi.fn(async (registrationId) => {
        expect(registrationId).toBe("registration-test");
        return {
          activity: "active",
          readable: true,
        } satisfies ComputeNodeWorkloadObservation;
      }),
    };

    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(tmpdir(), `.compute-node-activity-${crypto.randomUUID()}.json`),
      platform: "darwin",
      workloadObservation,
    });

    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({
      facets: { workActivity: "active" },
      status: "ready",
    });
    expect(workloadObservation.observe).toHaveBeenCalled();
  });

  it("bounds a stalled Workload activity read so lifecycle mutation can settle", async () => {
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
    const workloadObservation = new ComputeWorkloadActivityOwner(session, fetcher, 10);
    const service = await ComputeNodeService.open({
      installAuthorization: testInstallAuthorization,
      adapter: runtime,
      arch: "arm64",
      filePath: join(
        tmpdir(),
        `.compute-node-activity-timeout-${crypto.randomUUID()}.json`
      ),
      platform: "darwin",
      workloadObservation,
    });

    await expect(
      service.configure({ desiredEnabled: true, workspaceId: "wsp_test" })
    ).resolves.toMatchObject({
      status: "ready",
      facets: { workActivity: "unknown" },
    });
    expect(fetcher).toHaveBeenCalled();
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
      reportUnauthorized: vi.fn(async () => undefined),
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
  });
});
