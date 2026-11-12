import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
    failureCode = "host_start_failed";
  const requests: Record<string, unknown>[] = [];
  const run = vi.fn(async (_file: string, args: string[], stdin?: string) => {
    if (args[0] === "version") return JSON.stringify({ release_id: "installed" });
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
  const maintenance = new LocalHostMaintenance(
    preparation,
    join(directory, "intent"),
    run,
    confirm,
    undefined,
    { find: async () => [], signal: () => false, sleep: async () => {} },
    { now: () => 1000, setTimer: () => () => {} }
  );
  return {
    directory,
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
    installed: () => installed,
    uninstall: () => {
      installed = false;
    },
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
