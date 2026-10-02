import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { HostMaintenanceInput } from "@comma/native-bridge";
import { LocalHostMaintenance } from "../modules/compute-node/host-maintenance";
import type { LocalComputeOperator } from "../modules/compute-node/local-operator";
import {
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "../modules/compute-node/host-preparation";
import publishedHost from "../../../../../../.github/agent-vmm-host.json";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});

async function fixture(
  localDisposals?: Pick<
    LocalComputeOperator,
    "currentDisposalRequest" | "supersedeAfterHostReset"
  >
) {
  const home = await mkdtemp(join(tmpdir(), "comma-maintenance-"));
  directories.push(home);
  const config = resolveHostConfiguration("prod", {}, home);
  const journalDirectory = join(home, "maintenance");
  const sourceApp = join(home, "prepared", "Agent VMM Host.app");
  const sourceHelper = join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle");
  await mkdir(join(sourceApp, "Contents", "Helpers"), { recursive: true });
  await writeFile(sourceHelper, "verified test helper");
  await mkdir(config.appPath, { recursive: true });
  let installed = true;
  let release = "old-host-without-local-operator-rpcs";
  let receipt: Record<string, unknown> | null = null;
  let responseLost = false;
  let failNative = false;
  const nativeRequests: Record<string, unknown>[] = [];
  const run = vi.fn(async (command: string, args: string[], stdin?: string) => {
    if (args[0] === "version") {
      if (!installed) throw Object.assign(new Error("missing"), { code: "ENOENT" });
      return JSON.stringify({ release_id: release });
    }
    if (args[0] === "maintenance-status") return JSON.stringify(receipt);
    if (args[0] !== "maintenance" || command !== sourceHelper)
      throw new Error("Unexpected helper or command.");
    const request = JSON.parse(stdin!);
    nativeRequests.push(request);
    if (failNative) {
      failNative = false;
      receipt = {
        ...request,
        stage: "verifying",
        outcome: "failed",
        failureMessage: "Retained data cannot be restored.",
      };
      return JSON.stringify(receipt);
    }
    receipt = { ...request, stage: "complete", outcome: "succeeded" };
    if (request.action === "uninstall") {
      installed = false;
      await rm(config.appPath, { recursive: true, force: true });
    } else {
      installed = true;
      release = publishedHost.release_id;
      await mkdir(config.appPath, { recursive: true });
    }
    if (responseLost) {
      responseLost = false;
      throw new Error("Helper reply lost after commit.");
    }
    return JSON.stringify(receipt);
  });
  const preparation = new AgentVMMHostPreparation(config, run);
  const staged = {
    sourceApp,
    targetReleaseId: publishedHost.release_id,
    artifactSha256: "a".repeat(64),
    artifactSize: 123,
  };
  const stage = vi
    .spyOn(preparation, "stageMaintenance")
    .mockImplementation(async (_id, _report, _artifact, execute) => {
      await execute?.(staged);
      return staged;
    });
  const confirm = vi.fn(async () => true);
  const operator = () =>
    new LocalHostMaintenance(
      preparation,
      journalDirectory,
      run,
      confirm,
      localDisposals
    );
  return {
    operator,
    stage,
    confirm,
    run,
    nativeRequests,
    config,
    staged,
    journalDirectory,
    loseResponse: () => {
      responseLost = true;
    },
    failNative: () => {
      failNative = true;
    },
    setReceipt: (value: Record<string, unknown> | null) => {
      receipt = value;
    },
  };
}

describe("shared Host maintenance", () => {
  const actions: HostMaintenanceInput[] = [
    { action: "update", dataPolicy: "preserve" },
    { action: "reinstall", dataPolicy: "preserve" },
    { action: "reinstall", dataPolicy: "reset" },
    { action: "uninstall", dataPolicy: "preserve" },
    { action: "uninstall", dataPolicy: "reset" },
  ];
  it("retires only the projection of a superseded failure after the current owner completes", async () => {
    const local = {
      currentDisposalRequest: vi.fn(async () => "d559fe82-f45a-4f6a-b727-748d1328416c"),
      supersedeAfterHostReset: vi.fn(async () => {}),
    };
    const f = await fixture(local);
    f.failNative();
    const first = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "reset" });
    const original = await readFile(join(f.journalDirectory, "comma.json"), "utf8");
    await writeFile(
      join(f.journalDirectory, "state.json"),
      JSON.stringify({
        version: 1,
        uninstalled: false,
        latestRequest: "cli-latest",
        completedRequests: { "cli-latest": true },
        supersededRequests: { [first.operation!.requestId]: "cli-predecessor" },
      })
    );
    expect((await f.operator().state()).operation).toBeUndefined();
    await expect(f.operator().assertInstallationAllowed()).resolves.toBeUndefined();
    expect(await readFile(join(f.journalDirectory, "comma.json"), "utf8")).toBe(
      original
    );
    expect(local.supersedeAfterHostReset).not.toHaveBeenCalled();
    expect(f.nativeRequests).toHaveLength(1);
    expect(f.stage).toHaveBeenCalledTimes(1);
  });

  it.each(["active", "failed", "uninstalled", "unreadable"] as const)(
    "keeps an old failure blocked when the current owner is %s",
    async (status) => {
      const f = await fixture();
      f.failNative();
      const first = await f
        .operator()
        .maintain({ action: "reinstall", dataPolicy: "preserve" });
      await writeFile(
        join(f.journalDirectory, "state.json"),
        JSON.stringify({
          version: 1,
          uninstalled: status === "uninstalled",
          latestRequest: "cli-latest",
          ...(status === "active" ? { activeRequest: "cli-latest" } : {}),
          completedRequests: {
            "cli-latest": status === "unreadable" ? "invalid" : status !== "failed",
          },
          supersededRequests: { [first.operation!.requestId]: "cli-latest" },
        })
      );
      expect((await f.operator().state()).operation?.outcome).toBe("failed");
      await expect(f.operator().assertInstallationAllowed()).rejects.toThrow();
      expect(f.nativeRequests).toHaveLength(1);
    }
  );
  it.each([false, true])(
    "finds another owner's failed maintenance with a previous completed Main request=%s",
    async (hasHistory) => {
      const f = await fixture();
      if (hasHistory)
        await f.operator().maintain({ action: "update", dataPolicy: "preserve" });
      else await mkdir(f.journalDirectory, { recursive: true });
      await writeFile(
        join(f.journalDirectory, "state.json"),
        JSON.stringify({
          version: 1,
          activeRequest: "cli-maintenance",
          uninstalled: false,
        })
      );
      f.setReceipt({
        version: 1,
        requestId: "cli-maintenance",
        action: "reinstall",
        dataPolicy: "preserve",
        targetApp: f.config.appPath,
        ...f.staged,
        stage: "verifying",
        outcome: "failed",
      });
      const next = await f
        .operator()
        .maintain({ action: "uninstall", dataPolicy: "preserve" });
      expect(next.operation?.outcome).toBe("succeeded");
      expect(f.nativeRequests.at(-1)).toMatchObject({
        supersedesRequestId: "cli-maintenance",
      });
      expect(f.stage.mock.calls.at(-2)![0]).not.toBe(next.operation!.requestId);
    }
  );

  it.each(["pending", "missing"] as const)(
    "does not submit maintenance over an active owner's %s receipt",
    async (outcome) => {
      const f = await fixture();
      await mkdir(f.journalDirectory, { recursive: true });
      await writeFile(
        join(f.journalDirectory, "state.json"),
        JSON.stringify({
          version: 1,
          activeRequest: "cli-maintenance",
          uninstalled: false,
        })
      );
      f.setReceipt(
        outcome === "missing"
          ? null
          : {
              version: 1,
              requestId: "cli-maintenance",
              action: "reinstall",
              dataPolicy: "preserve",
              targetApp: f.config.appPath,
              ...f.staged,
              stage: "verifying",
              outcome,
            }
      );
      await expect(
        f.operator().maintain({ action: "uninstall", dataPolicy: "reset" })
      ).rejects.toThrow("existing maintenance");
      expect(f.confirm).not.toHaveBeenCalled();
      expect(f.nativeRequests).toHaveLength(0);
    }
  );

  it("may cache a verified owner preview but does not change it when confirmation is cancelled", async () => {
    const f = await fixture();
    await mkdir(f.journalDirectory, { recursive: true });
    await writeFile(
      join(f.journalDirectory, "state.json"),
      JSON.stringify({
        version: 1,
        activeRequest: "cli-maintenance",
        uninstalled: false,
      })
    );
    f.setReceipt({
      version: 1,
      requestId: "cli-maintenance",
      action: "uninstall",
      dataPolicy: "preserve",
      targetApp: f.config.appPath,
      stage: "removing",
      outcome: "failed",
    });
    f.confirm.mockResolvedValue(false);
    await f.operator().maintain({ action: "uninstall", dataPolicy: "reset" });
    expect(f.stage).toHaveBeenCalledTimes(1);
    expect(f.nativeRequests).toHaveLength(0);
    await expect(
      readFile(join(f.journalDirectory, "comma.json"))
    ).rejects.toMatchObject({ code: "ENOENT" });
  });
  it.each(
    actions.filter(
      (input) => input.action === "uninstall" || input.dataPolicy === "reset"
    )
  )(
    "replaces a confirmed native failure with a newly confirmed $action/$dataPolicy",
    async (input) => {
      const f = await fixture();
      f.failNative();
      const first = await f
        .operator()
        .maintain({ action: "reinstall", dataPolicy: "preserve" });
      expect(first.operation?.outcome).toBe("failed");
      const second = await f.operator().maintain(input);
      expect(second.operation?.outcome).toBe("succeeded");
      expect(f.confirm).toHaveBeenCalledTimes(2);
      expect(f.nativeRequests[1]).toMatchObject({
        ...input,
        supersedesRequestId: first.operation!.requestId,
      });
      expect(second.operation!.requestId).not.toBe(first.operation!.requestId);
      const old = JSON.parse(
        await readFile(
          join(
            f.journalDirectory,
            "comma-history",
            `${first.operation!.requestId}.json`
          ),
          "utf8"
        )
      );
      expect(old).toMatchObject({
        action: "reinstall",
        dataPolicy: "preserve",
        artifact: publishedHost,
        operation: { outcome: "failed" },
      });
      await expect(f.operator().resume(first.operation!.requestId)).rejects.toThrow(
        "original maintenance"
      );
      expect(f.nativeRequests).toHaveLength(2);
    }
  );

  it("keeps the original failed request when replacement confirmation is cancelled", async () => {
    const f = await fixture();
    f.failNative();
    const first = await f
      .operator()
      .maintain({ action: "update", dataPolicy: "preserve" });
    f.confirm.mockResolvedValue(false);
    expect(
      (await f.operator().maintain({ action: "uninstall", dataPolicy: "reset" }))
        .operation?.requestId
    ).toBe(first.operation!.requestId);
    expect(f.nativeRequests).toHaveLength(1);
    await expect(
      readFile(
        join(f.journalDirectory, "comma-history", `${first.operation!.requestId}.json`)
      )
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it.each(["pending", "unreadable"] as const)(
    "does not replace %s native work even when Main previously failed",
    async (outcome) => {
      const f = await fixture();
      f.failNative();
      await f.operator().maintain({ action: "reinstall", dataPolicy: "preserve" });
      f.setReceipt(
        outcome === "pending"
          ? { ...f.nativeRequests[0], stage: "verifying", outcome }
          : {}
      );
      await expect(
        f.operator().maintain({ action: "uninstall", dataPolicy: "reset" })
      ).rejects.toThrow("existing maintenance");
      expect(f.confirm).toHaveBeenCalledTimes(1);
      expect(f.nativeRequests).toHaveLength(1);
    }
  );

  it("does not retry effects for a request superseded by another local owner", async () => {
    const f = await fixture();
    f.failNative();
    const first = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "preserve" });
    f.setReceipt({
      ...f.nativeRequests[0],
      stage: "verifying",
      outcome: "superseded",
      supersededByRequestId: "ea1309f1-f3e8-486e-af32-ebd4f7b884fb",
    });
    const resumed = await f.operator().resume(first.operation!.requestId);
    expect(resumed.operation).toMatchObject({
      outcome: "failed",
      problem: expect.stringContaining("replaced"),
    });
    expect(f.nativeRequests).toHaveLength(1);
    expect(f.stage).toHaveBeenCalledTimes(1);
  });

  it("keeps the original supersession scope through an interrupted replacement download", async () => {
    const f = await fixture();
    f.failNative();
    const first = await f
      .operator()
      .maintain({ action: "update", dataPolicy: "preserve" });
    f.stage
      .mockImplementationOnce(f.stage.getMockImplementation()!)
      .mockRejectedValueOnce(new Error("offline"));
    const replacement = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "reset" });
    expect(replacement.operation?.outcome).toBe("failed");
    const resumed = await f.operator().resume(replacement.operation!.requestId);
    expect(resumed.operation?.outcome).toBe("succeeded");
    expect(f.nativeRequests[1]).toMatchObject({
      requestId: replacement.operation!.requestId,
      supersedesRequestId: first.operation!.requestId,
      action: "reinstall",
      dataPolicy: "reset",
    });
    expect(f.confirm).toHaveBeenCalledTimes(2);
  });

  it("uses a new confirmation without a stale supersession after another owner finishes the predecessor", async () => {
    const f = await fixture();
    f.failNative();
    const first = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "preserve" });
    f.stage
      .mockImplementationOnce(f.stage.getMockImplementation()!)
      .mockRejectedValueOnce(new Error("offline"));
    const replacement = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "reset" });
    f.setReceipt({ ...f.nativeRequests[0], stage: "complete", outcome: "succeeded" });
    const next = await f
      .operator()
      .maintain({ action: "uninstall", dataPolicy: "preserve" });
    expect(next.operation?.outcome).toBe("succeeded");
    expect(f.nativeRequests[1]).not.toHaveProperty("supersedesRequestId");
    expect(f.confirm).toHaveBeenCalledTimes(3);
    await expect(f.operator().resume(replacement.operation!.requestId)).rejects.toThrow(
      "original maintenance"
    );
    expect(first.operation?.outcome).toBe("failed");
  });

  it.each(["failed", "succeeded", "pending", "wrong-target"] as const)(
    "observes an external owner's %s latest receipt without resuming its operation",
    async (outcome) => {
      const f = await fixture();
      f.failNative();
      const first = await f
        .operator()
        .maintain({ action: "reinstall", dataPolicy: "preserve" });
      const originalRun = f.run.getMockImplementation()!;
      const other = {
        ...f.nativeRequests[0],
        requestId: "cli-maintenance",
        stage: "verifying",
        outcome: outcome === "wrong-target" ? "failed" : outcome,
        ...(outcome === "wrong-target"
          ? { targetApp: "/another/Agent VMM Host.app" }
          : {}),
      };
      f.run.mockImplementation(async (command, args, stdin) => {
        if (args[0] !== "maintenance-status") return originalRun(command, args, stdin);
        const request = JSON.parse(stdin!);
        if (!request.requestId) return JSON.stringify(other);
        if (request.requestId === first.operation!.requestId)
          return JSON.stringify({
            ...f.nativeRequests[0],
            stage: "verifying",
            outcome: "superseded",
            supersededByRequestId: other.requestId,
          });
        return "null";
      });
      const action = f
        .operator()
        .maintain({ action: "uninstall", dataPolicy: "preserve" });
      if (outcome === "failed" || outcome === "succeeded") {
        expect((await action).operation?.outcome).toBe("succeeded");
        expect(f.nativeRequests[1]!.supersedesRequestId).toBe(
          outcome === "failed" ? "cli-maintenance" : undefined
        );
        const journal = JSON.parse(
          await readFile(join(f.journalDirectory, "comma.json"), "utf8")
        );
        expect(journal.requestId).toBe(f.nativeRequests[1]!.requestId);
      } else {
        await expect(action).rejects.toThrow("existing maintenance");
        expect(f.confirm).toHaveBeenCalledTimes(1);
        expect(f.nativeRequests).toHaveLength(1);
      }
    }
  );
  it.each(actions)(
    "delivers a confirmed $action/$dataPolicy through the verified helper without cloud login",
    async (input) => {
      const f = await fixture();
      expect((await f.operator().state()).updateAvailable).toBe(true);
      expect(f.stage).not.toHaveBeenCalled();
      const state = await f.operator().maintain(input);
      expect(f.confirm).toHaveBeenCalledExactlyOnceWith(input);
      expect(f.nativeRequests).toHaveLength(1);
      expect(f.nativeRequests[0]).toMatchObject({
        ...input,
        confirmSharedHost: true,
        ...(input.dataPolicy === "reset" ? { confirmDataDeletion: true } : {}),
      });
      expect(f.nativeRequests[0]!.confirmDataDeletion).toBe(
        input.dataPolicy === "reset" ? true : undefined
      );
      expect(state.operation).toMatchObject({
        ...input,
        phase: "completed",
        outcome: "succeeded",
      });
      expect(state.installation).toBe(
        input.action === "uninstall" ? "not_installed" : "installed"
      );
      const journal = JSON.parse(
        await readFile(join(f.journalDirectory, "comma.json"), "utf8")
      );
      expect(journal.requestId).toBe(f.nativeRequests[0]!.requestId);
      if (input.action === "uninstall")
        expect(f.nativeRequests[0]).not.toHaveProperty("sourceApp");
      else
        expect(f.nativeRequests[0]).toMatchObject({
          targetReleaseId: publishedHost.release_id,
          artifactSha256: "a".repeat(64),
          artifactSize: 123,
        });
    }
  );

  it("does not prepare or mutate after native confirmation is cancelled", async () => {
    const f = await fixture();
    f.confirm.mockResolvedValue(false);
    await f.operator().maintain({ action: "uninstall", dataPolicy: "reset" });
    expect(f.stage).not.toHaveBeenCalled();
    expect(f.nativeRequests).toHaveLength(0);
    await expect(
      readFile(join(f.journalDirectory, "comma.json"))
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("persists the original confirmation before a failed download and resumes it after restart", async () => {
    const f = await fixture();
    f.stage.mockRejectedValueOnce(new Error("offline"));
    const first = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "reset" });
    expect(first.operation?.outcome).toBe("failed");
    const id = first.operation!.requestId;
    await expect(
      f.operator().maintain({ action: "update", dataPolicy: "preserve" })
    ).rejects.toThrow("existing maintenance");
    await expect(f.operator().resume("another-request")).rejects.toThrow(
      "original maintenance"
    );
    const second = await f.operator().resume(id);
    expect(second.operation?.outcome).toBe("succeeded");
    expect(f.confirm).toHaveBeenCalledTimes(1);
    expect(f.nativeRequests[0]).toMatchObject({
      requestId: id,
      action: "reinstall",
      dataPolicy: "reset",
    });
  });

  it("reads a lost native result without issuing a second destructive action", async () => {
    const f = await fixture();
    f.loseResponse();
    const first = await f
      .operator()
      .maintain({ action: "uninstall", dataPolicy: "reset" });
    expect(first.operation?.outcome).toBe("succeeded");
    await f.operator().resume(first.operation!.requestId);
    expect(f.nativeRequests).toHaveLength(1);
    expect(f.stage).toHaveBeenCalledTimes(1);
  });

  it("does not accept another target's successful receipt as completion", async () => {
    const f = await fixture();
    f.stage.mockRejectedValueOnce(new Error("offline"));
    const first = await f
      .operator()
      .maintain({ action: "reinstall", dataPolicy: "reset" });
    f.setReceipt({
      requestId: "other",
      action: "reinstall",
      dataPolicy: "reset",
      stage: "complete",
      outcome: "succeeded",
    });
    expect((await f.operator().state()).operation?.requestId).toBe(
      first.operation!.requestId
    );
    expect((await f.operator().state()).operation?.outcome).toBe("failed");
  });

  it("rejects reset-as-update before requesting any confirmation", async () => {
    const f = await fixture();
    await expect(
      f.operator().maintain({ action: "update", dataPolicy: "reset" })
    ).rejects.toThrow();
    expect(f.confirm).not.toHaveBeenCalled();
    expect(f.nativeRequests).toHaveLength(0);
  });

  it("uses current native policy rather than a historical Comma uninstall to gate setup", async () => {
    const f = await fixture();
    await f.operator().maintain({ action: "uninstall", dataPolicy: "preserve" });
    const path = join(f.journalDirectory, "state.json");
    await writeFile(path, JSON.stringify({ version: 1, uninstalled: true }));
    await expect(f.operator().assertInstallationAllowed()).rejects.toThrow(
      "explicitly reinstall"
    );
    // A separate local owner explicitly reinstalled; Main missed its own final receipt write.
    const journalPath = join(f.journalDirectory, "comma.json");
    const journal = JSON.parse(await readFile(journalPath, "utf8"));
    journal.operation.outcome = "pending";
    journal.operation.phase = "checking";
    await writeFile(journalPath, JSON.stringify(journal));
    await writeFile(path, JSON.stringify({ version: 1, uninstalled: false }));
    await expect(f.operator().assertInstallationAllowed()).resolves.toBeUndefined();
    expect(f.nativeRequests).toHaveLength(1);
    await writeFile(
      path,
      JSON.stringify({ version: 1, uninstalled: false, activeRequest: "another" })
    );
    await expect(f.operator().assertInstallationAllowed()).rejects.toThrow(
      "Continue local Host maintenance"
    );
  });

  it.each(["preserve", "reset"] as const)(
    "only %s maintenance settles a frozen local disposal",
    async (dataPolicy) => {
      const disposalRequestId = "d559fe82-f45a-4f6a-b727-748d1328416c";
      const local = {
        currentDisposalRequest: vi.fn(async () => disposalRequestId),
        supersedeAfterHostReset: vi.fn(async () => {}),
      };
      const f = await fixture(local);
      const result = await f.operator().maintain({ action: "reinstall", dataPolicy });
      if (dataPolicy === "reset") {
        expect(local.currentDisposalRequest).toHaveBeenCalledTimes(1);
        expect(local.supersedeAfterHostReset).toHaveBeenCalledWith(
          disposalRequestId,
          result.operation!.requestId
        );
      } else {
        expect(local.currentDisposalRequest).not.toHaveBeenCalled();
        expect(local.supersedeAfterHostReset).not.toHaveBeenCalled();
      }
    }
  );

  it("settles a failed auxiliary reset marker before allowing another maintenance request", async () => {
    const disposalRequestId = "d559fe82-f45a-4f6a-b727-748d1328416c";
    const settle = vi.fn(async () => {});
    settle.mockRejectedValueOnce(new Error("marker IO failed"));
    const f = await fixture({
      currentDisposalRequest: vi.fn(async () => disposalRequestId),
      supersedeAfterHostReset: settle,
    });
    await expect(
      f.operator().maintain({ action: "reinstall", dataPolicy: "reset" })
    ).rejects.toThrow("marker IO failed");
    const old = JSON.parse(
      await readFile(join(f.journalDirectory, "comma.json"), "utf8")
    );
    expect(old.operation.outcome).toBe("succeeded");
    await f.operator().maintain({ action: "update", dataPolicy: "preserve" });
    expect(settle).toHaveBeenLastCalledWith(disposalRequestId, old.requestId);
    expect(f.nativeRequests).toHaveLength(2);
  });
});
