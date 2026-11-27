import {
  access,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { LocalHostMaintenance } from "../modules/compute-node/host-maintenance";
import {
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "../modules/compute-node/host-preparation";
import type { NativeReceipt } from "../modules/compute-node/host-maintenance-protocol";
import publishedHost from "../../../../../../.github/agent-vmm-host.json";
import {
  ComputeNodeService,
  ComputeNodeCommandError,
  ComputeNodeSessionChangedError,
  runCommand,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeInstallAuthorizationOwner,
} from "../modules/compute-node";
import type { NativeRequestReceipt } from "../modules/compute-node/runtime-adapter";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});
async function fixture(env: NodeJS.ProcessEnv = {}) {
  const directory = await mkdtemp(join(tmpdir(), "comma-maintenance-"));
  directories.push(directory);
  const config = resolveHostConfiguration(
    env.COMMA_VMM_SOURCE_PATH ? "dev" : "prod",
    env,
    directory
  );
  await mkdir(config.appPath, { recursive: true });
  const sourceApp = join(directory, "frozen", "Agent VMM Host.app");
  await mkdir(join(sourceApp, "Contents", "Helpers"), { recursive: true });
  await writeFile(
    join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle"),
    "test helper"
  );
  let receipt: NativeReceipt | undefined;
  let succeeds = false,
    installed = false,
    helperInstalled = true,
    installedVersion: {
      contractVersion: number;
      release_id: string;
      currentSchema?: number;
    } = {
      contractVersion: 1,
      release_id: "installed",
    },
    failureCode = "host_start_failed";
  const requests: Record<string, unknown>[] = [];
  const run = vi.fn(async (file: string, args: string[], stdin?: string) => {
    // Like spawn, a removed installed helper fails with ENOENT.
    if (!helperInstalled && file === config.lifecyclePath)
      throw Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" });
    if (file !== config.lifecyclePath && !file.startsWith("/usr/bin/"))
      await access(file);
    if (args[0] === "version") return JSON.stringify(installedVersion);
    if (args[0] === "maintenance-status") return JSON.stringify(receipt ?? null);
    if (args[0] === "host-maintain") {
      const request = JSON.parse(stdin!);
      requests.push(request);
      receipt = {
        contractVersion: 1,
        version: 1,
        requestId: request.requestId,
        action: request.action,
        dataPolicy: request.dataPolicy,
        stage: "restore",
        outcome: succeeds ? "succeeded" : "failed",
        retryable: !succeeds,
        ...(!succeeds ? { failureCode } : {}),
      };
      if (succeeds) installed = request.action !== "uninstall";
      // Native removes only the installed Host bundle.
      if (succeeds && request.action === "uninstall") {
        helperInstalled = false;
        await rm(config.appPath, { recursive: true, force: true });
      }
      return JSON.stringify(receipt);
    }
    return "{}";
  });
  const preparation = new AgentVMMHostPreparation(config, run);
  const staged = vi
    .spyOn(preparation, "stageMaintenance")
    .mockImplementation(async (_requestId, _report, _artifact, consume) => {
      const prepared = {
        sourceApp,
        targetReleaseId:
          config.sourcePath || config.downloadUrlOverride
            ? "operator-release"
            : publishedHost.release_id,
      };
      await consume?.(prepared);
      return prepared;
    });
  const confirm = vi.fn(async () => true);
  const timers = new Set<() => void>();
  const maintenance = new LocalHostMaintenance(
    preparation,
    join(directory, "intent"),
    run,
    confirm,
    undefined,
    { find: async () => [], signal: () => false, sleep: async () => {} },
    {
      now: () => 1000,
      setTimer: (_ms, fire) => {
        timers.add(fire);
        return () => timers.delete(fire);
      },
    }
  );
  return {
    directory,
    timers,
    maintenance,
    requests,
    staged,
    preparation,
    confirm,
    setOutcome: (success: boolean) => {
      succeeds = success;
    },
    setFailureCode: (code: string) => {
      failureCode = code;
    },
    setInstalledVersion: (version: {
      contractVersion: number;
      release_id: string;
      currentSchema?: number;
    }) => {
      installedVersion = version;
    },
    installed: () => installed,
    uninstall: () => {
      installed = false;
    },
    config,
    run,
    removeInstalledHost: async () => {
      installed = false;
      helperInstalled = false;
      await rm(config.appPath, { recursive: true, force: true });
    },
    sourceApp,
  };
}

it("compares only published sources and keeps custom source candidates unknown while executing their exact staged target", async () => {
  const published = await fixture();
  expect(await published.maintenance.state()).toMatchObject({
    installedReleaseId: "installed",
    selectedReleaseId: publishedHost.release_id,
    updateAvailable: true,
  });
  for (const env of [
    { COMMA_VMM_DOWNLOAD_URL: "https://example.test/operator.zip" },
    { COMMA_VMM_SOURCE_PATH: "/test/operator-source" },
  ]) {
    const f = await fixture(env);
    const before = await f.maintenance.state();
    expect(before.selectedReleaseId).toBeUndefined();
    expect(before.updateAvailable).toBe(false);
    f.setOutcome(true);
    const after = await f.maintenance.maintain({
      action: "update",
      dataPolicy: "preserve",
    });
    expect(after).toMatchObject({
      installedReleaseId: "installed",
      updateAvailable: false,
    });
    expect(after.selectedReleaseId).toBeUndefined();
    expect(f.requests[0]).toMatchObject({
      targetReleaseId: "operator-release",
      action: "update",
      dataPolicy: "preserve",
    });
  }
});

async function setupFixture() {
  const f = await fixture();
  const receipts = new Map<string, NativeRequestReceipt>();
  let claimed = false;
  const owner: ComputeNodeInstallAuthorizationOwner = {
    authorize: vi.fn(async () => ({
      registrationId: "reg-setup",
      descriptor: "ticket",
    })),
    retry: vi.fn(async () => ({ registrationId: "reg-setup", descriptor: "ticket" })),
    inspect: async () => ({
      status: claimed ? "ready" : "processing",
      workActivity: "idle",
    }),
    observe: async () => (claimed ? "ready" : "processing"),
    configure: async () => "ready",
    revoke: async () => "removed",
  };
  const adapter: ComputeNodeRuntimeAdapter = {
    observe: async () => ({
      host: f.installed() ? "ready" : "absent",
      connector: claimed ? "ready" : "absent",
      salix: "unregistered",
      registration: claimed ? "present" : "absent",
      readability: "readable",
    }),
    receipt: async (request) => receipts.get(request),
    install: vi.fn(async (request) => {
      claimed = true;
      receipts.set(request!, {
        requestId: request!,
        targetRegistrationId: "reg-setup",
        kind: "registration-claim",
        outcome: "succeeded",
      });
    }),
    resume: async () => {},
    enable: async () => {},
    drain: async () => {},
    remove: async () => {},
    repair: async () => {},
  };
  const ensure = vi.spyOn(f.preparation, "ensure").mockImplementation(async () => {
    if (!f.installed())
      await runCommand(process.execPath, [
        "-e",
        `process.stdout.write(JSON.stringify({error:{code:"host_uninstalled",reason:"owner_uninstalled"}}));process.exitCode=1;`,
      ]);
  });
  const timers = new Set<() => void>();
  let generation = "account-1";
  const filePath = join(f.directory, "compute.json");
  const open = () =>
    ComputeNodeService.open({
      filePath,
      adapter,
      preparation: f.preparation,
      installAuthorization: owner,
      platform: "darwin",
      arch: "arm64",
      clock: {
        now: () => 1000,
        setTimer: (_ms, run) => {
          timers.add(run);
          return () => timers.delete(run);
        },
      },
      authorityGeneration: () => generation,
      reinstallHost: (explicit, requireCurrent) =>
        f.maintenance.prepareForSetup(explicit, requireCurrent),
    });
  return {
    ...f,
    filePath,
    open,
    ensure,
    adapter,
    owner,
    timers,
    changeAccount: () => {
      generation = "account-2";
    },
  };
}

it("continues the original explicit configure through confirmed preserve reinstall, and does not reuse historical success after another uninstall", async () => {
  const f = await setupFixture();
  f.setOutcome(true);
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const configure = service.state().currentRequest!.requestId;
  expect(f.confirm).toHaveBeenCalledWith({
    action: "reinstall",
    dataPolicy: "preserve",
  });
  expect(f.requests).toHaveLength(1);
  const maintenance = f.requests[0]!.requestId;
  expect(maintenance).not.toBe(configure);
  expect(f.requests[0]).toMatchObject({
    action: "reinstall",
    dataPolicy: "preserve",
    confirmSharedHost: true,
  });
  expect(f.adapter.install).toHaveBeenCalledWith(configure, "ticket");
  expect(service.state().status).toBe("ready");
  const saved = JSON.parse(
    await readFile(join(f.directory, "intent/comma.json"), "utf8")
  );
  expect(saved.requestId).toBe(maintenance);

  f.uninstall();
  expect(await f.maintenance.prepareForSetup(false, () => {})).toBeUndefined();
  expect(f.requests).toHaveLength(1);
  f.confirm.mockResolvedValueOnce(false);
  expect(await f.maintenance.prepareForSetup(true, () => {})).toBeUndefined();
  expect(f.requests).toHaveLength(1);
  await f.maintenance.prepareForSetup(true, () => {});
  expect(f.requests).toHaveLength(2);
  expect(f.requests[1]!.requestId).not.toBe(maintenance);
});

it("does not confirm reinstall from an old background configure, and cancelling explicit confirmation never authorizes", async () => {
  const f = await setupFixture();
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 1,
      desiredEnabled: true,
      workspaceId: "workspace",
      authorizationRequestId: "old-configure",
      request: { requestId: "old-configure", kind: "configure" },
      continuation: { deadlineAt: 100000 },
    })
  );
  const service = await f.open();
  await service.refresh();
  const pending = [...f.timers];
  f.timers.clear();
  pending.forEach((run) => run());
  await service.refresh();
  expect(f.confirm).not.toHaveBeenCalled();
  expect(f.requests).toHaveLength(0);
  expect(f.owner.authorize).not.toHaveBeenCalled();
  f.confirm.mockResolvedValueOnce(false);
  await service.continue();
  expect(f.confirm).toHaveBeenCalledTimes(1);
  expect(f.requests).toHaveLength(0);
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(service.state().currentRequest?.requestId).toBe("old-configure");
});

it("resumes only the confirmed pending reinstall ID, including background continuation, and preserves another pending action", async () => {
  const f = await setupFixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const original = service.state().currentRequest!.requestId;
  expect(f.requests).toHaveLength(1);
  expect(f.owner.authorize).not.toHaveBeenCalled();
  const maintenance = f.requests[0]!.requestId;
  await service.continue();
  expect(f.requests.map((request) => request.requestId)).toEqual([
    maintenance,
    maintenance,
  ]);
  expect(f.confirm).toHaveBeenCalledTimes(1);
  f.setOutcome(true);
  const pending = [...f.timers];
  f.timers.clear();
  pending.forEach((run) => run());
  await service.refresh();
  expect(f.requests.map((request) => request.requestId)).toEqual([
    maintenance,
    maintenance,
    maintenance,
  ]);
  expect(f.confirm).toHaveBeenCalledTimes(1);
  expect(f.adapter.install).toHaveBeenCalledWith(original, "ticket");

  f.setOutcome(false);
  await f.maintenance.maintain({ action: "update", dataPolicy: "preserve" });
  const before = f.requests.length;
  expect(await f.maintenance.prepareForSetup(true, () => {})).toBeUndefined();
  expect(f.requests).toHaveLength(before);
  expect(f.confirm).toHaveBeenCalledTimes(2);
});

it("fences a setup confirmation when the account changes, and refuses an unreadable saved maintenance intent", async () => {
  const f = await setupFixture();
  const service = await f.open();
  await service.refresh();
  f.confirm.mockImplementationOnce(async () => {
    f.changeAccount();
    return true;
  });
  await expect(
    service.configure({ desiredEnabled: true, workspaceId: "workspace" })
  ).rejects.toBeInstanceOf(ComputeNodeSessionChangedError);
  expect(f.requests).toHaveLength(0);
  expect(f.owner.authorize).not.toHaveBeenCalled();
  await mkdir(join(f.directory, "intent"), { recursive: true });
  await writeFile(join(f.directory, "intent/comma.json"), "invalid json");
  await expect(f.maintenance.prepareForSetup(true, () => {})).rejects.toThrow(
    "unreadable"
  );
  expect(f.confirm).toHaveBeenCalledTimes(1);
});

it("does not reinstall from a missing helper or a blocked old request", async () => {
  const f = await setupFixture();
  const service = await f.open();
  await service.refresh();
  f.ensure.mockRejectedValueOnce(
    Object.assign(new Error("helper absent"), { code: "ENOENT" })
  );
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  f.ensure.mockRejectedValueOnce(
    new ComputeNodeCommandError("old request blocked", "command_failed", {
      code: "host_uninstalled",
      reason: "request_blocked",
    })
  );
  await service.continue();
  expect(f.confirm).not.toHaveBeenCalled();
  expect(f.requests).toHaveLength(0);
  expect(f.owner.authorize).not.toHaveBeenCalled();
});
it("keeps the preflight's data refusal in the state, so the card can offer the only way on", async () => {
  const f = await fixture();
  f.setFailureCode("target_older_than_data");
  await f.maintenance.maintain({ action: "reinstall", dataPolicy: "preserve" });
  expect((await f.maintenance.state()).operation).toMatchObject({
    outcome: "failed",
    failureCode: "target_older_than_data",
  });
});
it("reads native maintenance without preparing a bundle and preserves data after repeated restore failures", async () => {
  const f = await fixture();
  await f.maintenance.state();
  expect(f.staged).not.toHaveBeenCalled();
  await f.maintenance.maintain({ action: "update", dataPolicy: "preserve" });
  const requestId = f.requests[0]!.requestId as string;
  for (let attempt = 0; attempt < 4; attempt++) await f.maintenance.resume(requestId);
  expect(f.requests).toHaveLength(5);
  expect(
    f.requests.every(
      (request) =>
        request.requestId === requestId &&
        request.action === "update" &&
        request.dataPolicy === "preserve"
    )
  ).toBe(true);
  expect(f.requests.slice(1).every((request) => request.continue === true)).toBe(true);
  expect((await f.maintenance.state()).operation).toMatchObject({
    requestId,
    outcome: "failed",
    failureCode: "host_start_failed",
  });
  const saved = JSON.parse(
    await readFile(join(f.directory, "intent", "comma.json"), "utf8")
  );
  expect(saved).toMatchObject({ requestId, action: "update", dataPolicy: "preserve" });
  expect(saved.operation).toBeUndefined();
});

it("shows a reinstall of a removed Agent VMM as preparing while it downloads, and continues it after an interrupted download", async () => {
  const f = await fixture();
  await f.removeInstalledHost();
  f.setOutcome(true);
  let phase: "idle" | "downloading" = "idle";
  const preparationState = f.preparation.state.bind(f.preparation);
  vi.spyOn(f.preparation, "state").mockImplementation(() => ({
    ...preparationState(),
    phase,
  }));
  let download!: () => void;
  let started!: () => void;
  const downloading = new Promise<void>((resolve) => {
    started = resolve;
  });
  const staging = f.staged.getMockImplementation()!;
  f.staged.mockImplementationOnce(async (...args) => {
    phase = "downloading";
    started();
    await new Promise<void>((resolve) => {
      download = resolve;
    });
    phase = "idle";
    return staging(...args);
  });
  const reinstall = f.maintenance.maintain({
    action: "reinstall",
    dataPolicy: "preserve",
  });
  await downloading;
  const during = await f.maintenance.state();
  expect(during.recordUnreadable).toBeUndefined();
  expect(during).toMatchObject({
    installation: "not_installed",
    preparationPhase: "downloading",
    operation: {
      action: "reinstall",
      dataPolicy: "preserve",
      phase: "preparing",
      outcome: "pending",
    },
  });
  download();
  expect((await reinstall).operation).toMatchObject({
    phase: "completed",
    outcome: "succeeded",
  });

  // A download that stops before staging leaves the confirmed request without a staged source.
  for (const resume of ["setup", "background"] as const) {
    const g = await fixture();
    await g.removeInstalledHost();
    g.staged.mockRejectedValueOnce(new Error("network lost"));
    const interrupted = await g.maintenance.maintain({
      action: "reinstall",
      dataPolicy: "preserve",
    });
    expect(interrupted.recordUnreadable).toBeUndefined();
    expect(interrupted.operation).toMatchObject({
      phase: "preparing",
      outcome: "pending",
    });
    const saved = JSON.parse(
      await readFile(join(g.directory, "intent", "comma.json"), "utf8")
    );
    expect(saved.sourceApp).toBeUndefined();
    g.setOutcome(true);
    if (resume === "setup") await g.maintenance.prepareForSetup(true, () => {});
    else expect(await g.maintenance.continuePending()).toBe(true);
    expect(g.requests.map((request) => request.requestId)).toEqual([saved.requestId]);
    expect(g.confirm).toHaveBeenCalledTimes(1);
  }
});

it("still reports an unreadable record when the saved request or its staged helper cannot be read", async () => {
  const f = await fixture();
  await f.removeInstalledHost();
  await mkdir(join(f.directory, "intent"), { recursive: true });
  await writeFile(join(f.directory, "intent", "comma.json"), "invalid json");
  expect((await f.maintenance.state()).recordUnreadable).toBe(true);

  const g = await fixture();
  await g.maintenance.maintain({ action: "reinstall", dataPolicy: "preserve" });
  await rm(g.sourceApp, { recursive: true, force: true });
  expect((await g.maintenance.state()).recordUnreadable).toBe(true);
});

/** Stages each request's bundle in the Host directory, as `stageMaintenance` does. */
async function stageInHostDirectory(f: Awaited<ReturnType<typeof fixture>>) {
  f.staged.mockImplementation(async (requestId, _report, _artifact, consume) => {
    const sourceApp = join(
      f.config.directory,
      `.maintenance-${requestId}`,
      "Agent VMM Host.app"
    );
    await mkdir(join(sourceApp, "Contents", "Helpers"), { recursive: true });
    await writeFile(
      join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle"),
      "staged"
    );
    const prepared = { sourceApp, targetReleaseId: publishedHost.release_id };
    await consume?.(prepared);
    return prepared;
  });
  await mkdir(join(f.config.directory, ".prepared"), { recursive: true });
  await writeFile(join(f.config.directory, ".prepared", "Host.zip.part"), "partial");
}
const maintenanceFiles = async (directory: string) =>
  (await readdir(directory)).filter(
    (name) =>
      name.startsWith(".maintenance-") ||
      name === ".prepared" ||
      name.startsWith(".Agent VMM Host.comma-update-")
  );

it("keeps one retained helper after settled maintenance, removes every bundle and the download cache, and reads the receipt without the Host", async () => {
  const f = await fixture();
  await stageInHostDirectory(f);
  await mkdir(join(f.config.directory, ".maintenance-old", "Agent VMM Host.app"), {
    recursive: true,
  });
  f.setOutcome(true);
  await f.maintenance.maintain({ action: "update", dataPolicy: "preserve" });
  await f.maintenance.maintain({ action: "reinstall", dataPolicy: "preserve" });
  expect(f.requests).toHaveLength(2);
  expect(await maintenanceFiles(f.config.directory)).toEqual([]);
  const saved = JSON.parse(
    await readFile(join(f.directory, "intent", "comma.json"), "utf8")
  );
  expect(saved).toMatchObject({
    requestId: f.requests[1]!.requestId,
    sourceApp: f.preparation.retainedApp,
  });
  // The receipt stays readable after the person removes the Host by hand.
  await f.removeInstalledHost();
  const state = await f.maintenance.state();
  expect(state.recordUnreadable).toBeUndefined();
  expect(state.operation).toMatchObject({
    requestId: saved.requestId,
    action: "reinstall",
    outcome: "succeeded",
  });
});

it("keeps the current bundle and download cache while a failed request can continue, and removes them once it settles", async () => {
  const f = await fixture();
  await stageInHostDirectory(f);
  await f.maintenance.maintain({ action: "update", dataPolicy: "preserve" });
  const requestId = f.requests[0]!.requestId as string;
  expect(await maintenanceFiles(f.config.directory)).toEqual(
    expect.arrayContaining([`.maintenance-${requestId}`, ".prepared"])
  );
  expect(
    await readFile(join(f.config.directory, ".prepared", "Host.zip.part"), "utf8")
  ).toBe("partial");
  f.setOutcome(true);
  await f.maintenance.resume(requestId);
  expect(f.requests.map((request) => request.requestId)).toEqual([
    requestId,
    requestId,
  ]);
  expect(await maintenanceFiles(f.config.directory)).toEqual([]);
});

it("uninstalls with the installed helper alone when it matches the published release, downloads nothing, and still reads the uninstall afterwards", async () => {
  const f = await fixture();
  f.setInstalledVersion({ contractVersion: 1, release_id: publishedHost.release_id });
  await mkdir(join(f.config.appPath, "Contents", "Helpers"), { recursive: true });
  await writeFile(f.config.lifecyclePath, "installed helper");
  f.setOutcome(true);
  await f.maintenance.maintain({ action: "uninstall", dataPolicy: "preserve" });
  expect(f.staged).not.toHaveBeenCalled();
  const retained = join(
    f.preparation.retainedApp,
    "Contents",
    "Helpers",
    "agent-vmm-lifecycle"
  );
  expect(await readFile(retained, "utf8")).toBe("installed helper");
  const maintain = f.run.mock.calls.find(([, args]) => args[0] === "host-maintain")!;
  expect(maintain[0]).toBe(retained);
  expect(JSON.parse(maintain[2]!)).not.toHaveProperty("sourceApp");
  expect(await readdir(f.config.directory)).not.toContain("Agent VMM Host.app");
  expect(await maintenanceFiles(f.config.directory)).toEqual([]);
  expect(await f.maintenance.state()).toMatchObject({
    installation: "not_installed",
    operation: { action: "uninstall", outcome: "succeeded", phase: "completed" },
  });
});

it("stages the published helper for uninstall when the installed helper is older, upgrades pending uninstalls, and never falls back offline", async () => {
  const f = await fixture();
  f.setInstalledVersion({ contractVersion: 1, release_id: "older-installed-release" });
  await mkdir(join(f.config.appPath, "Contents", "Helpers"), { recursive: true });
  await writeFile(f.config.lifecyclePath, "older installed helper");
  f.setOutcome(true);
  await f.maintenance.maintain({ action: "uninstall", dataPolicy: "preserve" });
  expect(f.staged).toHaveBeenCalledTimes(1);
  expect(f.staged.mock.calls[0]![2]).toEqual(publishedHost);

  // An unfinished uninstall persisted by an older Comma upgrades its artifact on continuePending.
  const g = await fixture();
  g.setInstalledVersion({ contractVersion: 1, release_id: "older-installed-release" });
  await mkdir(join(g.config.appPath, "Contents", "Helpers"), { recursive: true });
  await writeFile(g.config.lifecyclePath, "older installed helper");
  const pendingId = "11111111-1111-4111-8111-111111111111";
  await mkdir(join(g.directory, "intent"), { recursive: true });
  await writeFile(
    join(g.directory, "intent", "comma.json"),
    JSON.stringify({
      version: 2,
      requestId: pendingId,
      action: "uninstall",
      dataPolicy: "preserve",
      targetApp: g.config.appPath,
      artifact: { ...publishedHost, release_id: "older-published-release" },
      deadlineAt: 100_000,
    })
  );
  g.setOutcome(true);
  expect(await g.maintenance.continuePending()).toBe(true);
  expect(g.staged).toHaveBeenCalledTimes(1);
  expect(g.staged.mock.calls[0]![0]).toBe(pendingId);
  expect(g.staged.mock.calls[0]![2]).toEqual(publishedHost);
  expect(g.requests[0]).toMatchObject({ requestId: pendingId, action: "uninstall" });

  // Offline staging failure surfaces the error visibly and never falls back to the older installed helper.
  const h = await fixture();
  h.setInstalledVersion({ contractVersion: 1, release_id: "older-installed-release" });
  await mkdir(join(h.config.appPath, "Contents", "Helpers"), { recursive: true });
  await writeFile(h.config.lifecyclePath, "older installed helper");
  h.staged.mockRejectedValueOnce(new Error("network offline while downloading host"));
  const offlineState = await h.maintenance.maintain({
    action: "uninstall",
    dataPolicy: "preserve",
  });
  expect(h.requests).toHaveLength(0);
  expect(offlineState.operation).toMatchObject({
    action: "uninstall",
    phase: "preparing",
    outcome: "pending",
    problem: "network offline while downloading host",
  });
});

it("preempts a running maintenance task when clear (reset) is confirmed and records supersedesRequestId", async () => {
  const f = await fixture();
  let releaseFirst!: () => void;
  let firstStarted!: () => void;
  const started = new Promise<void>((resolve) => {
    firstStarted = resolve;
  });
  const baseRun = f.run.getMockImplementation()!;
  let firstRequestId: string | undefined;
  f.run.mockImplementation(async (file, args, stdin) => {
    if (args[0] === "host-maintain") {
      const req = JSON.parse(stdin!);
      if (!firstRequestId) {
        firstRequestId = req.requestId;
        await baseRun(file, args, stdin);
        firstStarted();
        await new Promise<void>((resolve) => {
          releaseFirst = resolve;
        });
        return JSON.stringify({
          contractVersion: 1,
          version: 1,
          requestId: req.requestId,
          action: req.action,
          dataPolicy: req.dataPolicy,
          stage: "stop",
          outcome: "pending",
          retryable: true,
        });
      }
    }
    return baseRun(file, args, stdin);
  });
  const stoppedPids: number[] = [];
  const maintenance = new LocalHostMaintenance(
    f.preparation,
    join(f.directory, "intent"),
    f.run,
    f.confirm,
    undefined,
    {
      find: async () => (firstRequestId ? [4242] : []),
      signal: (pid, sig) => {
        if (sig === "SIGTERM") {
          stoppedPids.push(pid);
          releaseFirst();
          return true;
        }
        return false;
      },
      sleep: async () => {},
    },
    { now: () => 1000, setTimer: () => () => {} }
  );
  const runningUpdate = maintenance.maintain({
    action: "update",
    dataPolicy: "preserve",
  });
  await started;
  f.setOutcome(true);
  const resetState = await maintenance.maintain({
    action: "reinstall",
    dataPolicy: "reset",
  });
  await runningUpdate;
  expect(stoppedPids).toContain(4242);
  expect(resetState.operation).toMatchObject({
    action: "reinstall",
    dataPolicy: "reset",
    outcome: "succeeded",
  });
  expect(f.requests[1]).toMatchObject({
    action: "reinstall",
    dataPolicy: "reset",
    supersedesRequestId: firstRequestId,
  });
});

it("tells its listeners once when an uninstall succeeds on a background retry", async () => {
  const f = await fixture();
  f.setInstalledVersion({ contractVersion: 1, release_id: publishedHost.release_id });
  await mkdir(join(f.config.appPath, "Contents", "Helpers"), { recursive: true });
  await writeFile(f.config.lifecyclePath, "installed helper");
  const settled = vi.fn();
  f.maintenance.onSettled(settled);
  expect(
    await f.maintenance.maintain({ action: "uninstall", dataPolicy: "preserve" })
  ).toMatchObject({ operation: { action: "uninstall", outcome: "failed" } });
  expect(settled).not.toHaveBeenCalled();
  expect(f.timers.size).toBe(1);
  f.setOutcome(true);
  // The retry timer runs exactly this continuation.
  expect(await f.maintenance.continuePending()).toBe(true);
  expect(settled).toHaveBeenCalledTimes(1);
  expect(settled.mock.calls[0]![0]).toMatchObject({
    installation: "not_installed",
    operation: { action: "uninstall", outcome: "succeeded" },
  });
  expect(f.timers.size).toBe(0);
  expect(await f.maintenance.continuePending()).toBe(false);
  await f.maintenance.state();
  expect(settled).toHaveBeenCalledTimes(1);
});

it("moves the helper of a request that an older Comma settled, then removes its bundle on an idle read", async () => {
  const f = await fixture();
  await stageInHostDirectory(f);
  f.setOutcome(true);
  // An older Comma kept the request's bundle after it settled.
  const retain = vi.spyOn(f.preparation, "retainHelper").mockResolvedValueOnce(false);
  await f.maintenance.maintain({ action: "update", dataPolicy: "preserve" });
  const requestId = f.requests[0]!.requestId as string;
  expect(await maintenanceFiles(f.config.directory)).toContain(
    `.maintenance-${requestId}`
  );
  retain.mockRestore();
  expect((await f.maintenance.state()).operation).toMatchObject({
    requestId,
    outcome: "succeeded",
  });
  expect(await maintenanceFiles(f.config.directory)).toEqual([]);
  expect(
    JSON.parse(await readFile(join(f.directory, "intent", "comma.json"), "utf8"))
      .sourceApp
  ).toBe(f.preparation.retainedApp);
});

it("removes the bundles of a reset that also removed Main's record, without writing the record again", async () => {
  const f = await fixture();
  await stageInHostDirectory(f);
  f.setOutcome(true);
  const record = join(f.directory, "intent", "comma.json");
  const native = f.run.getMockImplementation()!;
  // A data reset removes everything in the data directory except native's own journal.
  f.run.mockImplementation(async (file, args, stdin) => {
    const output = await native(file, args, stdin);
    if (args[0] === "host-maintain") await rm(record, { force: true });
    return output;
  });
  await f.maintenance.maintain({ action: "reinstall", dataPolicy: "reset" });
  expect(f.requests).toHaveLength(1);
  expect(await maintenanceFiles(f.config.directory)).toEqual([]);
  await expect(readFile(record)).rejects.toMatchObject({ code: "ENOENT" });
});
