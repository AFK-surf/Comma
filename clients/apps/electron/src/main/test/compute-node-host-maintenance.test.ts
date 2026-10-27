import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { HostMaintenanceInput } from "@comma/native-bridge";
import {
  LocalHostMaintenance,
  type HostProcessControl,
} from "../modules/compute-node/host-maintenance";
import { ComputeNodeCommandError } from "../modules/compute-node/command";
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

const STUCK = "097da22c-d8fe-4b4c-a3b3-b0540af83968";

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
  const policyPath = join(journalDirectory, "state.json");
  const sourceApp = join(home, "prepared", "Agent VMM Host.app");
  const sourceHelper = join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle");
  await mkdir(join(sourceApp, "Contents", "Helpers"), { recursive: true });
  await writeFile(sourceHelper, "verified test helper");
  await mkdir(config.appPath, { recursive: true });
  /** The helper that Main froze for one request under its own maintenance directory. */
  const frozenApp = (requestId: string) =>
    join(config.directory, `.maintenance-${requestId}`, "Agent VMM Host.app");
  const frozenHelper = (requestId: string) =>
    join(frozenApp(requestId), "Contents", "Helpers", "agent-vmm-lifecycle");
  const frozenVersions = new Map<string, Record<string, unknown>>();
  let installed = true;
  let release = "old-host-without-local-operator-rpcs";
  /** Receipts by request id, and the owner's latest receipt. */
  const receipts = new Map<string, Record<string, unknown>>();
  let receipt: Record<string, unknown> | null = null;
  const setReceipt = (value: Record<string, unknown> | null) => {
    receipt = value;
    if (value && typeof value.requestId === "string")
      receipts.set(value.requestId, value);
  };
  let responseLost = false;
  let failNative = false;
  const nativeAnswers: Record<string, unknown>[] = [];
  let ownerBusy = 0;
  let ownerPolicy = false;
  let hang: ((requestId: string) => Promise<never>) | undefined;
  let status: Record<string, unknown> = {};
  let targetSchemaMax: number | undefined;
  const nativeRequests: Record<string, unknown>[] = [];
  const nativeAttempts: Record<string, unknown>[] = [];
  /** The native owner's policy transition for an accepted request; a preflight refusal changes nothing. */
  const settlePolicy = async (request: Record<string, unknown>) => {
    if (!ownerPolicy || receipt?.failureCode === "target_older_than_data") return;
    const policy = JSON.parse(await readFile(policyPath, "utf8"));
    const id = request.requestId as string;
    const previous = request.supersedesRequestId as string | undefined;
    if (previous) {
      policy.supersededRequests = { ...policy.supersededRequests, [previous]: id };
      receipts.set(previous, {
        ...receipts.get(previous),
        outcome: "superseded",
        supersededByRequestId: id,
      });
    }
    policy.latestRequest = id;
    if (receipt?.outcome === "succeeded") {
      delete policy.activeRequest;
      policy.completedRequests = { ...policy.completedRequests, [id]: true };
    } else policy.activeRequest = id;
    await writeFile(policyPath, JSON.stringify(policy));
  };
  const run = vi.fn(async (command: string, args: string[], stdin?: string) => {
    if (args[0] === "version" && command === sourceHelper)
      return JSON.stringify({
        release_id: publishedHost.release_id,
        ...(targetSchemaMax === undefined
          ? {}
          : { supportedSchema: { min: 1, max: targetSchemaMax } }),
      });
    if (args[0] === "version" && frozenVersions.has(command))
      return JSON.stringify(frozenVersions.get(command));
    if (args[0] === "version") {
      if (!installed) throw Object.assign(new Error("missing"), { code: "ENOENT" });
      return JSON.stringify({ release_id: release });
    }
    if (args[0] === "status") return JSON.stringify(status);
    if (args[0] === "maintenance-status") {
      const requestId = stdin ? JSON.parse(stdin).requestId : undefined;
      return JSON.stringify(requestId ? (receipts.get(requestId) ?? null) : receipt);
    }
    if (args[0] !== "maintenance" || command !== sourceHelper)
      throw new Error("Unexpected helper or command.");
    const request = JSON.parse(stdin!);
    nativeAttempts.push(request);
    if (ownerBusy > 0) {
      ownerBusy--;
      throw new ComputeNodeCommandError(
        "Host maintenance: owner_busy: another executor holds the owner lock",
        "command_failed",
        { code: "owner_busy", reason: "operation_failed" }
      );
    }
    nativeRequests.push(request);
    if (hang) {
      const wait = hang;
      hang = undefined;
      setReceipt({ ...request, stage: "replacing", outcome: "pending" });
      await settlePolicy(request);
      return wait(request.requestId);
    }
    const answer = nativeAnswers.shift();
    if (answer) {
      setReceipt({ ...request, ...answer });
      await settlePolicy(request);
      return JSON.stringify(receipt);
    }
    if (failNative) {
      failNative = false;
      setReceipt({
        ...request,
        stage: "verifying",
        outcome: "failed",
        failureMessage: "Retained data cannot be restored.",
      });
      return JSON.stringify(receipt);
    }
    setReceipt({ ...request, stage: "complete", outcome: "succeeded" });
    await settlePolicy(request);
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
  /** This Mac's processes: an executable path each, and whether SIGTERM stops it. */
  const live = new Map<number, { path: string; term: boolean; exit?: () => void }>();
  const signals: [number, NodeJS.Signals][] = [];
  let nextPid = 4000;
  const processes: HostProcessControl = {
    find: async (path) =>
      [...live].filter(([, entry]) => entry.path === path).map(([pid]) => pid),
    signal: (pid, signal) => {
      const entry = live.get(pid);
      if (signal === 0) return !!entry;
      signals.push([pid, signal]);
      if (!entry) return false;
      if (signal === "SIGKILL" || entry.term) {
        live.delete(pid);
        entry.exit?.();
      }
      return true;
    },
    sleep: async () => {},
  };
  const spawn = (path: string, term = true, exit?: () => void) => {
    const pid = nextPid++;
    live.set(pid, { path, term, ...(exit ? { exit } : {}) });
    return pid;
  };
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
      localDisposals,
      processes
    );
  return {
    operator,
    preparation,
    stage,
    confirm,
    run,
    nativeRequests,
    nativeAttempts,
    config,
    staged,
    journalDirectory,
    frozenHelper,
    signals,
    processes,
    live,
    spawn,
    loseResponse: () => {
      responseLost = true;
    },
    failNative: () => {
      failNative = true;
    },
    setReceipt,
    /** The native owner's next answers to `maintenance`, such as a preflight refusal. */
    answerNative: (...values: Record<string, unknown>[]) => {
      nativeAnswers.push(...values);
    },
    /** The next `count` submissions find another executor holding the owner lock. */
    ownerBusy: (count: number) => {
      ownerBusy = count;
    },
    /** The next accepted request runs until its executor is stopped. */
    hangNative: () => {
      const started = new Promise<string>((resolve) => {
        hang = (requestId) => {
          resolve(requestId);
          return new Promise<never>((_resolve, reject) => {
            spawn(frozenHelper(requestId), true, () =>
              reject(new Error("Helper stopped by a signal."))
            );
          });
        };
      });
      return started;
    },
    setStatus: (value: Record<string, unknown>) => {
      status = value;
    },
    setTargetSchemaMax: (value: number | undefined) => {
      targetSchemaMax = value;
    },
    /** The native owner keeps its own policy, as `state.json` does, from now on. */
    writePolicy: async (value: Record<string, unknown>) => {
      ownerPolicy = true;
      await mkdir(journalDirectory, { recursive: true });
      await writeFile(policyPath, JSON.stringify(value));
    },
    /**
     * The incident: Main's request `STUCK`, frozen with a helper from before the fixes (no `supportedSchema`),
     * pending in its restore while the Host crash-loops, and its stale executor still running.
     */
    stuckRequest: async (helper: "old" | "fixed" = "old") => {
      await mkdir(join(frozenApp(STUCK), "Contents", "Helpers"), { recursive: true });
      await writeFile(frozenHelper(STUCK), "frozen helper");
      frozenVersions.set(frozenHelper(STUCK), {
        release_id: "agent-vmm-c170350",
        ...(helper === "fixed" ? { supportedSchema: { min: 1, max: 35 } } : {}),
      });
      ownerPolicy = true;
      await mkdir(journalDirectory, { recursive: true });
      await writeFile(
        policyPath,
        JSON.stringify({
          version: 1,
          activeRequest: STUCK,
          latestRequest: STUCK,
          uninstalled: false,
        })
      );
      const request = {
        version: 1,
        requestId: STUCK,
        action: "update",
        dataPolicy: "preserve",
        targetApp: config.appPath,
        sourceApp: frozenApp(STUCK),
        targetReleaseId: "agent-vmm-c170350",
        artifactSha256: "b".repeat(64),
        artifactSize: 99,
      };
      setReceipt({
        ...request,
        stage: "restoring",
        outcome: "pending",
        retryable: true,
      });
      await writeFile(
        join(journalDirectory, "comma.json"),
        JSON.stringify({
          version: 1,
          requestId: STUCK,
          action: "update",
          dataPolicy: "preserve",
          selectedReleaseId: "agent-vmm-c170350",
          targetApp: config.appPath,
          artifact: { ...publishedHost, release_id: "agent-vmm-c170350" },
          sourceApp: frozenApp(STUCK),
          targetReleaseId: "agent-vmm-c170350",
          operation: {
            requestId: STUCK,
            action: "update",
            dataPolicy: "preserve",
            phase: "installing",
            outcome: "pending",
          },
        })
      );
      status = {
        hostHealthy: false,
        hostRunning: false,
        hostStartFailure: { code: "data_requires_conversion", dataSchema: 35 },
        dataSchema: 35,
      };
      return spawn(frozenHelper(STUCK));
    },
  };
}

/** Main's receipt, as a previous Comma froze it on its own pinned release. */
const freezeOnPreviousRelease = async (journalDirectory: string) => {
  const path = join(journalDirectory, "comma.json");
  const journal = JSON.parse(await readFile(path, "utf8"));
  journal.artifact = { ...journal.artifact, release_id: "agent-vmm-previous" };
  journal.selectedReleaseId = "agent-vmm-previous";
  await writeFile(path, JSON.stringify(journal));
  return journal.requestId as string;
};

describe("shared Host maintenance", () => {
  it("reports download progress before native maintenance starts", async () => {
    const f = await fixture();
    let release!: () => void;
    const waiting = new Promise<void>((resolve) => {
      release = resolve;
    });
    let started!: () => void;
    const entered = new Promise<void>((resolve) => {
      started = resolve;
    });
    const originalState = f.preparation.state();
    vi.spyOn(f.preparation, "state").mockReturnValue({
      ...originalState,
      phase: "downloading",
    });
    f.stage.mockImplementation(async (_id, _report, _artifact, execute) => {
      started();
      await waiting;
      await execute?.(f.staged);
      return f.staged;
    });
    const owner = f.operator();
    const operation = owner.maintain({ action: "update", dataPolicy: "preserve" });
    await entered;
    try {
      expect(await owner.state()).toMatchObject({
        preparationPhase: "downloading",
        operation: { phase: "preparing", outcome: "pending" },
      });
      expect(f.nativeRequests).toHaveLength(0);
    } finally {
      release();
      await operation;
    }
    expect((await owner.state()).preparationPhase).toBeUndefined();
  });
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
      // Only an uninstall replaces a running request; another owner's executor is never Main's to stop.
      await expect(
        f
          .operator()
          .maintain(
            outcome === "pending"
              ? { action: "update", dataPolicy: "preserve" }
              : { action: "uninstall", dataPolicy: "reset" }
          )
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
  it.each(actions)(
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
        f
          .operator()
          .maintain(
            outcome === "pending"
              ? { action: "reinstall", dataPolicy: "preserve" }
              : { action: "uninstall", dataPolicy: "reset" }
          )
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
      // An uninstall also replaces another owner's pending request; its native lock fences a live executor.
      if (outcome !== "wrong-target") {
        expect((await action).operation?.outcome).toBe("succeeded");
        expect(f.nativeRequests[1]!.supersedesRequestId).toBe(
          outcome === "succeeded" ? undefined : "cli-maintenance"
        );
        expect(f.signals).toEqual([]);
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

  it("shows a Host that cannot start after maintenance with its confirmed reinstall", async () => {
    const f = await fixture();
    f.answerNative({
      stage: "accepted",
      outcome: "failed",
      failureCode: "host_start_failed",
      retryable: false,
    });
    const state = await f
      .operator()
      .maintain({ action: "update", dataPolicy: "preserve" });
    expect(state.operation).toMatchObject({
      outcome: "failed",
      failureCode: "host_start_failed",
    });
    await expect(f.operator().assertInstallationAllowed()).rejects.toThrow(
      "maintenance"
    );
  });

  it("keeps the current Host after a preflight refusal and stops offering that release", async () => {
    const f = await fixture();
    f.answerNative({
      stage: "accepted",
      outcome: "failed",
      failureCode: "target_older_than_data",
      retryable: false,
    });
    // The refusal changed nothing: no request is left to act on, and the release is not an update.
    const refused = await f
      .operator()
      .maintain({ action: "update", dataPolicy: "preserve" });
    expect(refused.operation).toBeUndefined();
    expect(refused.updateAvailable).toBe(false);
    await f.operator().assertInstallationAllowed();
    // Main does not start the refused release automatically again.
    await expect(f.operator().automaticUpdate()).rejects.toThrow("older than this Mac");
    expect(f.nativeRequests).toHaveLength(1);
    // The user's explicit update is a new request, not a continuation of the refused one.
    const next = await f
      .operator()
      .maintain({ action: "update", dataPolicy: "preserve" });
    expect(next.operation).toMatchObject({ outcome: "succeeded" });
    expect(f.nativeRequests[1]).not.toHaveProperty("supersedesRequestId");
  });

  it("updates automatically without a dialog only to a target that can open the local data", async () => {
    const f = await fixture();
    f.setStatus({
      hostStartFailure: { code: "data_newer_than_host", dataSchema: 35 },
    });
    expect((await f.operator().state()).hostStartFailure).toBe("data_newer_than_host");
    f.setTargetSchemaMax(25);
    await expect(f.operator().automaticUpdate()).rejects.toThrow("older than this Mac");
    expect(f.nativeRequests).toHaveLength(0);
    expect(await f.operator().state()).toMatchObject({ updateAvailable: false });
    expect((await f.operator().state()).operation).toBeUndefined();

    const g = await fixture();
    g.setStatus({ hostStartFailure: { code: "data_newer_than_host", dataSchema: 35 } });
    g.setTargetSchemaMax(35);
    const updated = await g.operator().automaticUpdate();
    expect(g.confirm).not.toHaveBeenCalled();
    expect(g.nativeRequests).toEqual([
      expect.objectContaining({ action: "update", dataPolicy: "preserve" }),
    ]);
    expect(updated.operation?.outcome).toBe("succeeded");
  });

  it("reads a newer or extended receipt leniently and resets only an unreadable one", async () => {
    const f = await fixture();
    const done = await f
      .operator()
      .maintain({ action: "update", dataPolicy: "preserve" });
    const path = join(f.journalDirectory, "comma.json");
    const saved = JSON.parse(await readFile(path, "utf8"));
    await writeFile(path, JSON.stringify({ ...saved, futureField: { any: 1 } }));
    expect((await f.operator().state()).operation?.requestId).toBe(
      done.operation!.requestId
    );
    expect(await f.operator().resetRecord()).toBe(false);
    await writeFile(path, "{ not json");
    expect(await f.operator().state()).toMatchObject({ recordUnreadable: true });
    await expect(f.operator().assertInstallationAllowed()).rejects.toThrow(
      "Reset the local record"
    );
    expect(await f.operator().resetRecord()).toBe(true);
    const reset = await f.operator().state();
    expect(reset.recordUnreadable).toBeUndefined();
    expect(reset.operation).toBeUndefined();
    await f.operator().assertInstallationAllowed();
  });
});

describe("stuck Host maintenance recovery", () => {
  it("stops only the stale executor of a stuck request and updates over it without a dialog", async () => {
    const f = await fixture();
    f.setTargetSchemaMax(40);
    const stale = await f.stuckRequest();
    // Other processes: the installed Host helper, another request's helper, a same-named binary elsewhere.
    const installed = f.spawn(f.config.lifecyclePath);
    const other = f.spawn(f.frozenHelper("aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"));
    const elsewhere = f.spawn(
      "/tmp/Agent VMM Host.app/Contents/Helpers/agent-vmm-lifecycle"
    );
    expect(await f.operator().continuePending()).toBe(true);
    expect(f.signals).toEqual([[stale, "SIGTERM"]]);
    expect([...f.live.keys()]).toEqual([installed, other, elsewhere]);
    expect(f.confirm).not.toHaveBeenCalled();
    expect(f.nativeRequests).toEqual([
      expect.objectContaining({
        action: "update",
        dataPolicy: "preserve",
        supersedesRequestId: STUCK,
        targetReleaseId: publishedHost.release_id,
      }),
    ]);
    const state = await f.operator().state();
    expect(state.operation).toMatchObject({ action: "update", outcome: "succeeded" });
    expect(state.automaticReset).toBeUndefined();
  });

  it("erases and reinstalls over the failed update, once, and reports it", async () => {
    const disposalRequestId = "d559fe82-f45a-4f6a-b727-748d1328416c";
    const local = {
      currentDisposalRequest: vi.fn(async () => disposalRequestId),
      supersedeAfterHostReset: vi.fn(async () => {}),
    };
    const f = await fixture(local);
    f.setTargetSchemaMax(40);
    await f.stuckRequest();
    f.answerNative({
      stage: "restoring",
      outcome: "failed",
      failureCode: "host_start_failed",
    });
    const operator = f.operator();
    const hostReset = vi.fn();
    operator.onHostReset(hostReset);
    await operator.continuePending();
    // Only the confirmed reset step, not the failed update, tells the compute service its registrations are gone.
    expect(hostReset).toHaveBeenCalledOnce();
    const [update, reset] = f.nativeRequests;
    expect(update).toMatchObject({ action: "update", supersedesRequestId: STUCK });
    expect(reset).toMatchObject({
      action: "reinstall",
      dataPolicy: "reset",
      confirmDataDeletion: true,
      supersedesRequestId: update!.requestId,
    });
    expect(f.confirm).not.toHaveBeenCalled();
    expect(local.supersedeAfterHostReset).toHaveBeenCalledWith(
      disposalRequestId,
      reset!.requestId
    );
    expect(await f.operator().state()).toMatchObject({
      operation: { action: "reinstall", dataPolicy: "reset", outcome: "succeeded" },
      automaticReset: true,
    });
  });

  it.each([
    {
      name: "a target schema older than the data",
      target: 25,
      status: {},
      refuses: false,
    },
    {
      name: "an unreadable data schema",
      target: 40,
      status: { dataSchemaIssue: "locked" },
      refuses: false,
    },
    { name: "a native preflight refusal", target: 40, status: {}, refuses: true },
  ])("erases and reinstalls over the stuck request directly for $name", async (row) => {
    const f = await fixture();
    f.setTargetSchemaMax(row.target);
    await f.stuckRequest();
    if (row.status.dataSchemaIssue)
      f.setStatus({ hostHealthy: false, dataSchema: 0, ...row.status });
    if (row.refuses)
      f.answerNative({
        stage: "accepted",
        outcome: "failed",
        failureCode: "target_older_than_data",
      });
    await f.operator().continuePending();
    // A refused or unchecked update leaves the stuck request active, so the reset names it.
    expect(
      f.nativeRequests.map((request) => [request.action, request.supersedesRequestId])
    ).toEqual([...(row.refuses ? [["update", STUCK]] : []), ["reinstall", STUCK]]);
    expect((await f.operator().state()).automaticReset).toBe(true);
  });

  it("stops the executor again while the native owner is busy, within a bound", async () => {
    const f = await fixture();
    f.setTargetSchemaMax(40);
    const stale = await f.stuckRequest();
    f.live.get(stale)!.term = false;
    f.ownerBusy(1);
    await f.operator().continuePending();
    expect(f.signals).toEqual([
      [stale, "SIGTERM"],
      [stale, "SIGKILL"],
    ]);
    expect(f.nativeAttempts).toHaveLength(2);
    expect(f.nativeAttempts[1]!.requestId).toBe(f.nativeAttempts[0]!.requestId);
    expect((await f.operator().state()).operation?.outcome).toBe("succeeded");

    const g = await fixture();
    g.setTargetSchemaMax(40);
    await g.stuckRequest();
    g.ownerBusy(10);
    await g.operator().continuePending();
    // Busy is not a step taken: no reset follows, and the stuck request is not superseded.
    expect(g.nativeAttempts).toHaveLength(3);
    expect(g.nativeAttempts.every((request) => request.action === "update")).toBe(true);
    expect((await g.operator().state()).operation?.outcome).toBe("failed");
  });

  it.each([
    { helper: "fixed" as const, healthy: false },
    { helper: "old" as const, healthy: true },
  ])(
    "continues a healthy in-progress request instead of recovering it ($helper helper, healthy Host=$healthy)",
    async ({ helper, healthy }) => {
      const f = await fixture();
      await f.stuckRequest(helper);
      const journal = JSON.parse(
        await readFile(join(f.journalDirectory, "comma.json"), "utf8")
      );
      await writeFile(
        join(f.journalDirectory, "comma.json"),
        JSON.stringify({ ...journal, ...f.staged })
      );
      f.setStatus({ hostHealthy: healthy, dataSchema: 35 });
      await f.operator().continuePending();
      expect(f.signals).toEqual([]);
      expect(f.nativeRequests).toEqual([
        expect.objectContaining({ requestId: STUCK, action: "update" }),
      ]);
      expect(f.nativeRequests[0]).not.toHaveProperty("supersedesRequestId");
    }
  );

  it("does not repeat an accepted step after a relaunch", async () => {
    const f = await fixture();
    f.setTargetSchemaMax(40);
    await f.stuckRequest();
    f.answerNative(
      { stage: "restoring", outcome: "failed", failureCode: "host_start_failed" },
      { stage: "restoring", outcome: "pending", retryable: true }
    );
    await f.operator().continuePending();
    // Relaunch while the reset runs: Main continues the same reset, not a second update.
    await f.operator().continuePending();
    expect(f.nativeRequests.map((request) => request.action)).toEqual([
      "update",
      "reinstall",
      "reinstall",
    ]);
    expect(f.nativeRequests[2]!.requestId).toBe(f.nativeRequests[1]!.requestId);
    expect((await f.operator().state()).automaticReset).toBe(true);

    const g = await fixture();
    g.setTargetSchemaMax(40);
    await g.stuckRequest();
    g.answerNative(
      { stage: "restoring", outcome: "failed", failureCode: "host_start_failed" },
      { stage: "restoring", outcome: "failed", failureCode: "host_start_failed" }
    );
    await g.operator().continuePending();
    expect(await g.operator().continuePending()).toBe(false);
    expect(g.nativeRequests).toHaveLength(2);
    // Both steps are spent: the person sees why, with the confirmed reinstall.
    expect((await g.operator().state()).operation).toMatchObject({
      outcome: "failed",
      failureCode: "host_start_failed",
    });
  });

  it("resumes a retryable failure with its own request id and keeps one reset per episode", async () => {
    const f = await fixture();
    f.setTargetSchemaMax(40);
    await f.stuckRequest();
    const stopFailed = {
      stage: "stopping",
      outcome: "failed",
      failureCode: "maintenance_incomplete",
      retryable: true,
    };
    f.answerNative(stopFailed, stopFailed);
    await f.operator().continuePending();
    // A stop that did not finish is no reason to erase the data: no reset follows the update.
    expect(f.nativeRequests.map((request) => request.action)).toEqual(["update"]);
    expect((await f.operator().state()).operation).toMatchObject({
      outcome: "failed",
      failedPhase: "stopping",
    });
    // Each continuation round and "Continue maintenance" run the same request again.
    expect(await f.operator().continuePending()).toBe(true);
    await f.operator().resume(f.nativeRequests[0]!.requestId as string);
    expect(f.nativeRequests.map((request) => request.requestId)).toEqual(
      Array(3).fill(f.nativeRequests[0]!.requestId)
    );
    expect((await f.operator().state()).operation?.outcome).toBe("succeeded");

    const g = await fixture();
    g.setTargetSchemaMax(40);
    await g.stuckRequest();
    g.answerNative(
      { stage: "restoring", outcome: "failed", failureCode: "host_start_failed" },
      stopFailed,
      stopFailed
    );
    for (let round = 0; round < 3; round++) await g.operator().continuePending();
    // The episode's one reset runs again; Main never adds a second reset over it.
    expect(g.nativeRequests.map((request) => request.action)).toEqual([
      "update",
      "reinstall",
      "reinstall",
      "reinstall",
    ]);
    expect(
      new Set(g.nativeRequests.slice(1).map((request) => request.requestId)).size
    ).toBe(1);
    expect((await g.operator().state()).automaticReset).toBe(true);
  });

  it("takes the reset step once after the recovery update failed retryably three times", async () => {
    const f = await fixture();
    f.setTargetSchemaMax(40);
    await f.stuckRequest();
    const stopFailed = {
      stage: "stopping",
      outcome: "failed",
      failureCode: "maintenance_incomplete",
      retryable: true,
    };
    // Three failed runs of the update, then a reset that fails twice the same way before it completes.
    f.answerNative(stopFailed, stopFailed, stopFailed, stopFailed, stopFailed);
    for (let round = 0; round < 6; round++) await f.operator().continuePending();
    const [update, reset] = [f.nativeRequests[0]!, f.nativeRequests[3]!];
    expect(
      f.nativeRequests.map((request) => [request.action, request.requestId])
    ).toEqual([
      ...Array.from({ length: 3 }, () => ["update", update.requestId]),
      ...Array.from({ length: 3 }, () => ["reinstall", reset.requestId]),
    ]);
    expect(reset).toMatchObject({
      dataPolicy: "reset",
      supersedesRequestId: update.requestId,
    });
    expect(f.confirm).not.toHaveBeenCalled();
    expect(await f.operator().state()).toMatchObject({
      operation: { action: "reinstall", outcome: "succeeded" },
      automaticReset: true,
    });
  });

  it("replaces a retryable failure frozen on another release with the pinned release", async () => {
    const stopFailed = {
      stage: "stopping",
      outcome: "failed",
      failureCode: "maintenance_incomplete",
      retryable: true,
    };
    // Main's automatic reset: owner-approved, so continuation replaces it without a dialog.
    const f = await fixture();
    f.setTargetSchemaMax(40);
    await f.stuckRequest();
    f.answerNative(
      { stage: "restoring", outcome: "failed", failureCode: "host_start_failed" },
      stopFailed
    );
    await f.operator().continuePending();
    const frozen = await freezeOnPreviousRelease(f.journalDirectory);
    expect(await f.operator().continuePending()).toBe(true);
    expect(f.confirm).not.toHaveBeenCalled();
    expect(f.nativeRequests.at(-1)).toMatchObject({
      action: "reinstall",
      dataPolicy: "reset",
      confirmDataDeletion: true,
      supersedesRequestId: frozen,
      targetReleaseId: publishedHost.release_id,
    });
    expect(f.stage.mock.lastCall?.[2]).toEqual(publishedHost);
    expect((await f.operator().state()).automaticReset).toBe(true);

    // The person's own reset: only the person's confirmed "Continue maintenance" replaces it.
    const g = await fixture();
    await g.writePolicy({ version: 1, uninstalled: false });
    g.answerNative(stopFailed);
    const input = { action: "reinstall", dataPolicy: "reset" } as const;
    await g.operator().maintain(input);
    const own = await freezeOnPreviousRelease(g.journalDirectory);
    expect(await g.operator().continuePending()).toBe(false);
    g.confirm.mockResolvedValueOnce(false);
    await g.operator().resume(own);
    expect(g.nativeRequests).toHaveLength(1);
    await g.operator().resume(own);
    expect(g.confirm).toHaveBeenLastCalledWith(input);
    expect(g.nativeRequests).toHaveLength(2);
    expect(g.nativeRequests[1]).toMatchObject({
      ...input,
      supersedesRequestId: own,
      targetReleaseId: publishedHost.release_id,
    });
    expect((await g.operator().state()).operation?.outcome).toBe("succeeded");
  });

  it("runs the person's failed request again when the person asks for the same action", async () => {
    const f = await fixture();
    await f.writePolicy({ version: 1, uninstalled: false });
    f.answerNative({
      stage: "stopping",
      outcome: "failed",
      failureCode: "maintenance_incomplete",
      retryable: true,
    });
    const input = { action: "reinstall", dataPolicy: "reset" } as const;
    await f.operator().maintain(input);
    await f.operator().maintain(input);
    expect(f.confirm).toHaveBeenCalledTimes(2);
    expect(f.nativeRequests.map((request) => request.requestId)).toEqual([
      f.nativeRequests[0]!.requestId,
      f.nativeRequests[0]!.requestId,
    ]);
    expect((await f.operator().state()).operation?.outcome).toBe("succeeded");
  });

  it("uninstalls over a stuck request after confirmation and stops only its executor", async () => {
    const f = await fixture();
    const stale = await f.stuckRequest();
    const other = f.spawn(f.config.lifecyclePath);
    const state = await f
      .operator()
      .maintain({ action: "uninstall", dataPolicy: "preserve" });
    expect(f.confirm).toHaveBeenCalledExactlyOnceWith({
      action: "uninstall",
      dataPolicy: "preserve",
    });
    expect(f.signals).toEqual([[stale, "SIGTERM"]]);
    expect(f.live.has(other)).toBe(true);
    expect(f.nativeRequests).toEqual([
      expect.objectContaining({ action: "uninstall", supersedesRequestId: STUCK }),
    ]);
    expect(state.operation).toMatchObject({
      action: "uninstall",
      outcome: "succeeded",
    });
  });

  it("uninstalls while Main's own maintenance call still runs", async () => {
    const f = await fixture();
    await f.writePolicy({ version: 1, uninstalled: false });
    const started = f.hangNative();
    const owner = f.operator();
    const update = owner.maintain({ action: "update", dataPolicy: "preserve" });
    const running = await started;
    f.processes.sleep = async () => {
      await update;
    };
    const uninstalled = await owner.maintain({
      action: "uninstall",
      dataPolicy: "preserve",
    });
    expect((await update).operation).toMatchObject({
      requestId: running,
      outcome: "pending",
    });
    expect(f.confirm).toHaveBeenCalledTimes(2);
    expect(f.nativeRequests.at(-1)).toMatchObject({
      action: "uninstall",
      supersedesRequestId: running,
    });
    expect(uninstalled.operation).toMatchObject({
      action: "uninstall",
      outcome: "succeeded",
    });
  });
});
