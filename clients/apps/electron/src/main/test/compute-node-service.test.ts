import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import {
  ComputeNodeCommandError,
  ComputeNodeService,
  AgentVMMCommandAdapter,
  ComputeNodeSessionChangedError,
  type ComputeNodeInstallAuthorizationOwner,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeRuntimeObservation,
} from "../modules/compute-node";
import type { NativeRequestReceipt } from "../modules/compute-node/runtime-adapter";
import type { MainClock } from "../clock";
import type { HostPreparationState } from "../modules/compute-node/host-preparation";
import { AccountComputeNodeService } from "../modules/compute-node/account-service";
import { LocalComputeOperator } from "../modules/compute-node/local-operator";
import type { LocalHostMaintenance } from "../modules/compute-node/host-maintenance";
import type { HostMaintenanceState } from "@comma/native-bridge";
import { ComputeNodeTicketNotRetryableError } from "../modules/compute-node/install-authorization";
import { signedInSessionSnapshotSchema } from "@comma/session-contract";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "comma-registration-"));
  directories.push(directory);
  const filePath = join(directory, "intent.json");
  const receipts = new Map<string, NativeRequestReceipt>();
  let status: "processing" | "ready" | "stopped" | "removed" = "processing";
  let present = false;
  const clock: MainClock = { now: () => 1000, setTimer: () => () => {} };
  const owner: ComputeNodeInstallAuthorizationOwner = {
    authorize: vi.fn(async () => ({
      registrationId: "reg-1",
      descriptor: '{"registration_id":"reg-1"}',
    })),
    retry: vi.fn(async () => ({
      registrationId: "reg-1",
      descriptor: '{"registration_id":"reg-1"}',
    })),
    inspect: vi.fn(async () => ({
      status,
      workActivity: "idle" as const,
      shellPhase: "failed" as const,
    })),
    observe: async () => status,
    configure: vi.fn(async ({ enabled }) => {
      status = enabled ? "ready" : "stopped";
      return status;
    }),
    revoke: vi.fn(async () => {
      status = "removed";
      return status;
    }),
  };
  const done = (requestId: string, kind: string) =>
    receipts.set(requestId, {
      requestId,
      targetRegistrationId: "reg-1",
      kind,
      outcome: "succeeded",
    });
  const adapter: ComputeNodeRuntimeAdapter = {
    observe: vi.fn(
      async (): Promise<ComputeNodeRuntimeObservation> => ({
        host: "ready",
        connector: present ? "ready" : "absent",
        readability: "readable",
        salix: "unregistered",
        registration: present ? "present" : "absent",
      })
    ),
    receipt: vi.fn(async (requestId) => receipts.get(requestId)),
    install: vi.fn(async (requestId) => {
      present = true;
      status = "ready";
      done(requestId!, "registration-claim");
    }),
    resume: vi.fn(async (requestId) => {
      present = true;
      status = "ready";
      done(requestId, "registration-claim");
    }),
    enable: vi.fn(async (requestId) => {
      status = "ready";
      done(requestId!, "registration-enable");
    }),
    drain: vi.fn(async (requestId) => {
      done(requestId!, "registration-drain");
    }),
    remove: vi.fn(async (requestId) => {
      present = false;
      done(requestId!, "registration-remove");
    }),
    repair: vi.fn(async () => {}),
  };
  const open = (runtime = adapter) =>
    ComputeNodeService.open({
      filePath,
      adapter: runtime,
      installAuthorization: owner,
      platform: "darwin",
      arch: "arm64",
      clock,
    });
  return { filePath, adapter, owner, receipts, open, clock };
}

it("continues a native claim beyond twelve failures with the same request and ignores Shell readiness", async () => {
  const f = await fixture();
  const fail = async (requestId?: string) => {
    f.receipts.set(requestId!, {
      requestId: requestId!,
      targetRegistrationId: "reg-1",
      kind: "registration-claim",
      outcome: "failed",
      retryable: true,
    });
    throw new Error("connection unavailable");
  };
  f.adapter.install = vi.fn(fail);
  f.adapter.resume = vi.fn(fail);
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const request = service.state().currentRequest!.requestId;
  for (let attempt = 0; attempt < 15; attempt++) await service.continue();
  expect(service.state().currentRequest?.requestId).toBe(request);
  expect(f.owner.authorize).toHaveBeenCalledTimes(1);
  expect(f.adapter.resume).toHaveBeenCalledTimes(15);
  f.adapter.resume = async (requestId) => {
    f.receipts.set(requestId, {
      requestId,
      targetRegistrationId: "reg-1",
      kind: "registration-claim",
      outcome: "succeeded",
    });
  };
  // A successful connection is a cloud/native observation, independent of initial Shell failure.
  f.adapter.observe = async () => ({
    host: "ready",
    connector: "ready",
    readability: "readable",
    salix: "ready",
    registration: "present",
  });
  f.owner.inspect = async () => ({
    status: "ready",
    workActivity: "idle",
    shellPhase: "failed",
  });
  await service.continue();
  expect(service.state().status).toBe("ready");
});

it("observes a succeeded claim on Continue, respects a later cloud stop, and gives a new explicit enable a new request", async () => {
  const f = await fixture();
  const ensure = vi.fn(async () => {});
  const service = await ComputeNodeService.open({
    filePath: f.filePath,
    adapter: f.adapter,
    installAuthorization: f.owner,
    platform: "darwin",
    arch: "arm64",
    clock: f.clock,
    preparation: {
      state: () => ({
        source: "download",
        location: "fixture",
        instance: "shared",
        phase: "ready",
      }),
      ensure,
      rebuild: async () => {},
    },
  });
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const claim = service.state().currentRequest!.requestId;
  f.owner.inspect = vi.fn(async () => ({
    status: "processing" as const,
    workActivity: "idle" as const,
  }));
  await service.continue();
  await service.continue();
  expect(f.owner.configure).not.toHaveBeenCalled();
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(f.adapter.install).toHaveBeenCalledTimes(1);
  expect(ensure).toHaveBeenCalledTimes(1);
  expect(service.state().currentRequest?.requestId).toBe(claim);
  expect(service.state().status).toBe("processing");
  expect(service.state().deadlineAt).toBeDefined();

  f.owner.inspect = vi.fn(async () => ({
    status: "stopped" as const,
    workActivity: "idle" as const,
  }));
  await service.refresh();
  expect(service.state()).toMatchObject({ status: "stopped", desiredEnabled: false });
  await service.continue();
  expect(service.state()).toMatchObject({ status: "stopped", desiredEnabled: false });
  expect(f.owner.configure).not.toHaveBeenCalled();
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(ensure).toHaveBeenCalledTimes(1);
  expect(JSON.parse(await readFile(f.filePath, "utf8")).continuation).toBeUndefined();

  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const enable = service.state().currentRequest!.requestId;
  expect(enable).not.toBe(claim);
  expect(f.owner.configure).toHaveBeenCalledOnce();
  expect(f.adapter.enable).toHaveBeenCalledWith(enable, "reg-1");
  expect(ensure).toHaveBeenCalledTimes(2);
});

/** Product entry point, native adapter and a separate receipt-owning helper process; no real Host is touched. */
async function observingClaim() {
  const f = await fixture();
  const nativeFile = join(f.filePath + ".native.json");
  const helper = join(f.filePath + ".helper");
  await writeFile(
    nativeFile,
    JSON.stringify({ connected: false, unreadable: false, calls: [], receipt: null })
  );
  await writeFile(
    helper,
    `#!${process.execPath}
const fs = require('node:fs');
const file = ${JSON.stringify(nativeFile)};
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
const args = process.argv.slice(2), command = args[0];
state.calls.push(command);
let result;
if (command === 'status') result = {contractVersion:1,hostInstalled:true,hostLoaded:true,hostReadable:true,hostHealthy:true,connectorInstalled:true,connectorLoaded:state.connected,registrationRead:state.receipt?'present':'absent',registrationState:'enabled'};
else if (command === 'operation') result = state.unreadable ? {invalid:'receipt'} : state.receipt;
else if (command === 'registration-claim') {
 const descriptor = JSON.parse(fs.readFileSync(0, 'utf8'));
 state.receipt = {requestId:args[args.indexOf('--request-id')+1],targetRegistrationId:descriptor.registration_id,kind:'registration-claim',outcome:'succeeded'};
 result = state.receipt;
} else throw new Error('Unexpected native mutation: '+command);
fs.writeFileSync(file, JSON.stringify(state));
process.stdout.write(JSON.stringify(result));
`,
    { mode: 0o700 }
  );
  let now = 1000,
    nextId = 0;
  const timers = new Map<number, { delay: number; run: () => void }>();
  const clock: MainClock = {
    now: () => now,
    setTimer: (delay, run) => {
      const key = ++nextId;
      timers.set(key, { delay, run });
      return () => {
        timers.delete(key);
      };
    },
  };
  let publish:
    | ((state: import("@comma/native-bridge").ComputeNodeState) => void)
    | undefined;
  const ensure = vi.fn(async () => {});
  const adapter = new AgentVMMCommandAdapter(helper);
  f.owner.inspect = vi.fn(async () => ({
    status: "ready" as const,
    workActivity: "idle" as const,
  }));
  const open = () =>
    ComputeNodeService.open({
      filePath: f.filePath,
      adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock,
      onStateChanged: (state) => {
        publish?.(state);
        publish = undefined;
      },
      preparation: {
        ensure,
        rebuild: async () => {},
        state: () => ({
          source: "download",
          location: "fixture",
          instance: "shared",
          phase: "ready",
        }),
      },
    });
  const service = await open();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const native = async () =>
    JSON.parse(await readFile(nativeFile, "utf8")) as {
      connected: boolean;
      unreadable: boolean;
      calls: string[];
      receipt: NativeRequestReceipt;
    };
  const changeNative = async (update: {
    connected?: boolean;
    unreadable?: boolean;
  }) => {
    await writeFile(nativeFile, JSON.stringify({ ...(await native()), ...update }));
  };
  const fire = async () => {
    expect(timers.size).toBe(1);
    const [key, timer] = timers.entries().next().value!;
    timers.delete(key);
    expect(timer.delay).toBeLessThanOrEqual(30_000);
    const changed = new Promise<import("@comma/native-bridge").ComputeNodeState>(
      (resolve) => {
        publish = resolve;
      }
    );
    timer.run();
    return changed;
  };
  const assertOneMutation = async () => {
    expect(
      (await native()).calls.filter((command) => command.startsWith("registration-"))
    ).toEqual(["registration-claim"]);
    expect(f.owner.authorize).toHaveBeenCalledOnce();
    expect(f.owner.configure).not.toHaveBeenCalled();
    expect(f.owner.retry).not.toHaveBeenCalled();
    expect(ensure).toHaveBeenCalledOnce();
  };
  return {
    service,
    open,
    timers,
    native,
    changeNative,
    fire,
    assertOneMutation,
    filePath: f.filePath,
    expire: () => {
      now += 45 * 60_000;
    },
  };
}

it("automatically observes a successful native claim until the connection is ready without replaying setup", async () => {
  const f = await observingClaim();
  const request = f.service.state().currentRequest!.requestId;
  expect(f.service.state()).toMatchObject({
    status: "processing",
    operation: { outcome: "succeeded" },
  });
  expect(f.service.state().deadlineAt).toBeDefined();
  expect((await f.fire()).status).toBe("processing");
  await f.changeNative({ connected: true });
  expect(await f.fire()).toMatchObject({
    status: "ready",
    currentRequest: { requestId: request },
    operation: { outcome: "succeeded" },
  });
  expect(f.timers.size).toBe(0);
  await f.assertOneMutation();
});

it("bounds successful-claim observation while running and automatically resumes on restart", async () => {
  const f = await observingClaim();
  const request = f.service.state().currentRequest!.requestId;
  f.expire();
  expect(await f.fire()).toMatchObject({
    status: "action_required",
    problem: "continuation_paused",
    primaryAction: "continue",
    operation: { outcome: "succeeded" },
  });
  expect(f.timers.size).toBe(0);
  const expired = JSON.parse(await readFile(f.filePath, "utf8"));
  expect(expired.continuation).toBeDefined();
  const restarted = await f.open();
  await restarted.refresh();
  expect(restarted.state()).toMatchObject({
    status: "processing",
    currentRequest: { requestId: request },
    operation: { outcome: "succeeded" },
  });
  expect(restarted.state().problem).toBeUndefined();
  expect(f.timers.size).toBe(1);
  await f.changeNative({ connected: true });
  expect((await f.fire()).status).toBe("ready");
  expect(restarted.state().problem).toBeUndefined();
  await f.assertOneMutation();
});

it("keeps an accelerated successful observation read-only when its receipt temporarily becomes unreadable", async () => {
  const f = await observingClaim();
  await f.changeNative({ unreadable: true });
  f.service.networkRecovered();
  expect(await f.fire()).toMatchObject({
    status: "action_required",
    problem: "operation_unknown",
    operation: { outcome: "unknown" },
  });
  expect(f.timers.size).toBe(0);
  await f.assertOneMutation();
});

it("projects exact native revocation after local disposal without changing cloud authority or replaying a successful claim", async () => {
  const f = await fixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const request = service.state().currentRequest!.requestId;
  f.adapter.observe = async () => ({
    host: "ready",
    connector: "stopped",
    readability: "readable",
    salix: "unregistered",
    registration: "present",
    registrationState: "revoked",
  });
  await service.refresh();
  expect(service.state()).toMatchObject({
    status: "action_required",
    problem: "registration_revoked",
    primaryAction: "remove",
    currentRequest: { requestId: request },
    operation: { outcome: "succeeded" },
  });
  await service.continue();
  expect(service.state().problem).toBe("registration_revoked");
  expect(f.owner.configure).not.toHaveBeenCalled();
  expect(f.owner.revoke).not.toHaveBeenCalled();
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(f.adapter.install).toHaveBeenCalledTimes(1);
});

it("refreshes Main once after a trusted local disposal so its cached cloud card observes native revocation", async () => {
  const f = await fixture();
  let revoked = false;
  const originalObserve = f.adapter.observe;
  f.adapter.observe = vi.fn(
    async (...args: Parameters<ComputeNodeRuntimeAdapter["observe"]>) => ({
      ...(await originalObserve(...args)),
      ...(revoked ? { registrationState: "revoked" as const } : {}),
    })
  );
  const local = new LocalComputeOperator({
    lifecyclePath: "helper",
    journalDirectory: join(f.filePath + ".disposals"),
    confirm: async () => true,
    run: async (_file, args, stdin) => {
      const body = JSON.parse(stdin ?? "{}");
      if (args[0] === "local-environments")
        return JSON.stringify({
          collectedAt: "now",
          environments: [
            {
              id: "env",
              origin: "remote",
              registrationId: "reg-1",
              state: "unknown",
              revision: "1",
            },
          ],
        });
      if (args[0] === "local-disk") return JSON.stringify({ collectedAt: "now" });
      if (args[0] === "local-plan")
        return JSON.stringify({
          plan: {
            targetKind: body.targetKind,
            targetId: body.targetId,
            revision: "1",
            environmentCount: "1",
          },
        });
      if (args[0] === "local-execute") {
        revoked = true;
        return JSON.stringify({
          operation: {
            id: "local-receipt",
            kind: "local-disposal",
            requestId: body.requestId,
            resource: { kind: "environment", environmentId: "reg-1" },
            state: "OPERATION_STATE_SUCCEEDED",
          },
        });
      }
      throw new Error("unexpected local command");
    },
  });
  const session = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account", email: "account@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const account = new AccountComputeNodeService(
    {
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
    },
    session,
    local
  );
  await account.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const page = await account.localOverview({});
  const before = vi.mocked(f.adapter.observe).mock.calls.length;
  await account.disposeLocal({ key: page.environments[0]!.disposalScope!.key });
  expect(vi.mocked(f.adapter.observe).mock.calls.length).toBe(before + 1);
  expect(account.state()).toMatchObject({
    status: "action_required",
    problem: "registration_revoked",
    primaryAction: "remove",
  });
  expect(f.owner.revoke).not.toHaveBeenCalled();
  expect(f.adapter.enable).not.toHaveBeenCalled();
});

it("dispatches an accepted enable by its original kind and never revives terminal or superseded requests", async () => {
  const f = await fixture();
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 1,
      desiredEnabled: true,
      workspaceId: "workspace",
      registrationId: "reg-1",
      request: { requestId: "accepted-enable", kind: "configure" },
    })
  );
  f.adapter.observe = async () => ({
    host: "ready",
    connector: "ready",
    readability: "readable",
    salix: "unregistered",
    registration: "present",
  });
  f.receipts.set("accepted-enable", {
    requestId: "accepted-enable",
    targetRegistrationId: "reg-1",
    kind: "registration-enable",
    outcome: "pending",
  });
  f.adapter.enable = vi.fn(async () => {
    f.receipts.set("accepted-enable", {
      requestId: "accepted-enable",
      targetRegistrationId: "reg-1",
      kind: "registration-enable",
      outcome: "failed",
      retryable: true,
    });
  });
  const service = await f.open();
  await service.refresh();
  await service.continue();
  await service.continue();
  // open() automatically resumed the pending accepted-enable once, followed by two explicit continues.
  expect(f.adapter.enable).toHaveBeenCalledTimes(3);
  expect(f.adapter.enable).toHaveBeenNthCalledWith(1, "accepted-enable", "reg-1");
  expect(f.adapter.enable).toHaveBeenNthCalledWith(2, "accepted-enable", "reg-1");
  expect(f.adapter.enable).toHaveBeenNthCalledWith(3, "accepted-enable", "reg-1");
  expect(f.owner.configure).not.toHaveBeenCalled();
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(f.owner.retry).not.toHaveBeenCalled();
  expect(f.adapter.resume).not.toHaveBeenCalled();
  expect(f.adapter.install).not.toHaveBeenCalled();

  f.receipts.get("accepted-enable")!.retryable = false;
  await service.continue();
  expect(f.adapter.enable).toHaveBeenCalledTimes(3);
  expect(service.state().primaryAction).toBe("check_status");
  f.receipts.get("accepted-enable")!.outcome = "superseded";
  await service.continue();
  expect(f.adapter.enable).toHaveBeenCalledTimes(3);
  expect(service.state().currentRequest?.requestId).toBe("accepted-enable");
  expect(service.state().status).toBe("action_required");
});

it("requires root recovery for an accepted legacy install instead of replaying it as a new claim", async () => {
  const f = await fixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const request = service.state().currentRequest!.requestId;
  f.receipts.set(request, {
    requestId: request,
    targetRegistrationId: "reg-1",
    kind: "install-managed",
    outcome: "pending",
  });
  await service.continue();
  expect(service.state()).toMatchObject({
    status: "action_required",
    problem: "authorization_attention",
    primaryAction: "recover",
  });
  expect(f.adapter.resume).not.toHaveBeenCalled();
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(f.owner.configure).not.toHaveBeenCalled();
});

it("treats an unsupported receipt getter or a mismatched accepted kind or target as unknown", async () => {
  const f = await fixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const request = service.state().currentRequest!.requestId;
  for (const receipt of [
    {
      requestId: request,
      targetRegistrationId: "other-reg",
      kind: "registration-claim",
      outcome: "succeeded" as const,
    },
    {
      requestId: request,
      targetRegistrationId: "reg-1",
      kind: "registration-remove",
      outcome: "succeeded" as const,
    },
  ]) {
    f.receipts.set(request, receipt);
    await service.continue();
    expect(service.state()).toMatchObject({
      problem: "operation_unknown",
      operation: { outcome: "unknown" },
    });
  }
  delete f.adapter.receipt;
  await service.continue();
  expect(service.state()).toMatchObject({
    problem: "operation_unknown",
    currentRequest: { requestId: request },
  });
  expect(f.owner.configure).not.toHaveBeenCalled();
  expect(f.owner.retry).not.toHaveBeenCalled();
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(f.adapter.resume).not.toHaveBeenCalled();
  expect(f.adapter.install).toHaveBeenCalledTimes(1);
});

it("does not adopt an accepted receipt when the saved intent has no Registration target", async () => {
  const f = await fixture();
  f.adapter.receipt = async (requestId) => ({
    requestId,
    kind: "registration-claim",
    outcome: "succeeded",
  });
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  expect(service.state()).toMatchObject({
    problem: "operation_unknown",
    operation: { outcome: "unknown" },
  });
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(f.adapter.install).not.toHaveBeenCalled();
});

it("preserves a future-version read-only intent when observing a completed request", async () => {
  const f = await fixture();
  const intent = {
    version: 6,
    revision: 1,
    desiredEnabled: true,
    workspaceId: "workspace",
    registrationId: "reg-1",
    request: { requestId: "future-request", kind: "configure" },
    continuation: { deadlineAt: 100000 },
  };
  await writeFile(f.filePath, JSON.stringify(intent));
  f.receipts.set("future-request", {
    requestId: "future-request",
    targetRegistrationId: "reg-1",
    kind: "registration-claim",
    outcome: "succeeded",
  });
  const service = await f.open();
  await service.refresh();
  expect(JSON.parse(await readFile(f.filePath, "utf8"))).toEqual(intent);
  await expect(service.continue()).rejects.toThrow("newer Comma");
});

it("continues cloud removal with the same request after native removal succeeded but cloud revocation was unknown", async () => {
  const f = await fixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const revoke = f.owner.revoke;
  f.owner.revoke = vi
    .fn()
    .mockRejectedValueOnce(new Error("cloud revocation unknown"))
    .mockImplementation(revoke);
  await service.remove();
  const request = service.state().currentRequest!.requestId;
  expect(service.state()).toMatchObject({
    status: "action_required",
    primaryAction: "continue",
    problem: "removal_failed",
    operation: { outcome: "succeeded" },
  });
  await service.continue();
  expect(service.state()).toMatchObject({
    status: "removed",
    currentRequest: { requestId: request },
  });
  expect(f.owner.revoke).toHaveBeenCalledTimes(2);
  expect(f.adapter.remove).toHaveBeenNthCalledWith(1, request, "reg-1");
  expect(f.adapter.remove).toHaveBeenNthCalledWith(2, request, "reg-1");
});

it("reopens a failed remove as Continue remove and never enables that registration", async () => {
  const f = await fixture(),
    service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  f.adapter.remove = vi.fn(async (requestId) => {
    f.receipts.set(requestId!, {
      requestId: requestId!,
      targetRegistrationId: "reg-1",
      kind: "registration-remove",
      outcome: "failed",
      retryable: true,
    });
    throw new Error("local removal interrupted");
  });
  await service.remove();
  const requestId = service.state().currentRequest!.requestId;
  const reopened = await f.open();
  await reopened.refresh();
  expect(reopened.state()).toMatchObject({
    primaryAction: "continue",
    currentRequest: { requestId, kind: "remove" },
    desiredEnabled: false,
  });
  f.adapter.remove = vi.fn(async (request) => {
    f.receipts.set(request!, {
      requestId: request!,
      targetRegistrationId: "reg-1",
      kind: "registration-remove",
      outcome: "succeeded",
    });
  });
  await reopened.continue();
  expect(f.adapter.remove).toHaveBeenCalledWith(requestId, "reg-1");
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(reopened.state().status).toBe("removed");
});

it("stops an enable while its claim is running and discards the late result", async () => {
  const f = await fixture(),
    accepted = deferred<void>(),
    started = deferred<void>();
  f.adapter.install = vi.fn(async () => {
    started.resolve();
    await accepted.promise;
  });
  const service = await f.open();
  await service.refresh();
  const enabling = service.configure({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
  await started.promise;
  await service.drain();
  expect(f.adapter.drain).toHaveBeenCalled();
  accepted.resolve();
  await enabling;
  expect(service.state()).toMatchObject({
    desiredEnabled: false,
    currentRequest: { kind: "drain" },
    status: "stopped",
  });
});

it("saves late accepted authorization only to the original account and fences all later effects", async () => {
  const f = await fixture(),
    accepted = deferred<{ registrationId: string; descriptor: string }>(),
    started = deferred<void>();
  let generation: string | undefined = "account-a";
  f.owner.authorize = async () => {
    started.resolve();
    return accepted.promise;
  };
  const service = await ComputeNodeService.open({
    filePath: f.filePath,
    adapter: f.adapter,
    installAuthorization: f.owner,
    platform: "darwin",
    arch: "arm64",
    clock: f.clock,
    authorityGeneration: () => generation,
    accountOwner: { audience: "https://example.test", subject: "account-a" },
  });
  await service.refresh();
  const enabling = service.configure({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
  await started.promise;
  generation = undefined;
  accepted.resolve({ registrationId: "reg-1", descriptor: "secret" });
  await expect(enabling).rejects.toBeInstanceOf(ComputeNodeSessionChangedError);
  expect(JSON.parse(await readFile(f.filePath, "utf8"))).toMatchObject({
    registrationId: "reg-1",
    accountOwner: { subject: "account-a" },
  });
  expect(f.adapter.install).not.toHaveBeenCalled();
});

it("lets configure continue the same request while an unreadable native receipt still fails closed", async () => {
  const f = await fixture(),
    service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const request = service.state().currentRequest!.requestId;
  f.adapter.receipt = async () => {
    throw new Error("unreadable database");
  };
  await service.refresh();
  expect(service.state()).toMatchObject({
    status: "action_required",
    problem: "operation_unknown",
    primaryAction: "continue",
    operation: { outcome: "unknown" },
  });
  await service.continue();
  expect(service.state()).toMatchObject({
    status: "action_required",
    problem: "operation_unknown",
    currentRequest: { requestId: request, kind: "configure" },
    operation: { outcome: "unknown" },
  });
  expect(f.owner.authorize).toHaveBeenCalledTimes(1);
  expect(f.owner.retry).not.toHaveBeenCalled();
  expect(f.owner.configure).not.toHaveBeenCalled();
  expect(f.adapter.install).toHaveBeenCalledTimes(1);
  expect(f.adapter.enable).not.toHaveBeenCalled();
  expect(f.adapter.resume).not.toHaveBeenCalled();
});

it("persists only a native-acknowledged legacy recovery correlation", async () => {
  const f = await fixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  f.owner.recoveryDescriptor = () => '{"registration_id":"reg-1"}';
  f.adapter.recover = vi.fn(async (requestId) => {
    const receipt: NativeRequestReceipt = {
      requestId: "legacy-native-request",
      correlationRequestId: requestId,
      targetRegistrationId: "reg-1",
      kind: "registration-recover",
      outcome: "failed",
      retryable: true,
    };
    f.receipts.set(receipt.requestId, receipt);
    return receipt;
  });
  const state = service.state();
  await service.reauthorize({
    workspaceId: "workspace",
    registrationId: "reg-1",
    bindingRevision: state.bindingRevision!,
  });
  expect(service.state().currentRequest?.requestId).toBe("legacy-native-request");
  expect(JSON.parse(await readFile(f.filePath, "utf8")).request.requestId).toBe(
    "legacy-native-request"
  );
});

it("recovers only the native receipt's explicit request correlation after a lost recovery reply", async () => {
  const f = await fixture();
  const service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  f.owner.recoveryDescriptor = () => '{"registration_id":"reg-1"}';
  let original: NativeRequestReceipt | undefined;
  f.adapter.recover = async (requestId) => {
    original = {
      requestId: "legacy-native-request",
      correlationRequestId: requestId,
      targetRegistrationId: "reg-1",
      kind: "registration-recover",
      outcome: "failed",
      retryable: true,
    };
    throw new Error("accepted recovery reply lost");
  };
  f.adapter.receipt = async (requestId, registrationId) =>
    original &&
    registrationId === "reg-1" &&
    (requestId === original.correlationRequestId || requestId === original.requestId)
      ? original
      : f.receipts.get(requestId);
  const state = service.state();
  await service.reauthorize({
    workspaceId: "workspace",
    registrationId: "reg-1",
    bindingRevision: state.bindingRevision!,
  });
  expect(service.state().currentRequest?.requestId).toBe("legacy-native-request");
});

it("keeps an unaccepted recovery distinct from the same Registration's successful claim", async () => {
  const f = await fixture();
  let claim: NativeRequestReceipt | undefined;
  let recovering = "";
  const run = vi.fn(async (_file: string, args: string[]) => {
    const requestId = args[args.indexOf("--request-id") + 1];
    if (args[0] === "status")
      return JSON.stringify({
        contractVersion: 1,
        hostInstalled: true,
        hostLoaded: true,
        hostReadable: true,
        hostHealthy: true,
        connectorLoaded: true,
        registrationRead: "present",
      });
    if (args[0] === "registration-claim") {
      claim = {
        requestId: requestId!,
        targetRegistrationId: "reg-1",
        kind: "registration-claim",
        outcome: "succeeded",
      };
      return JSON.stringify(claim);
    }
    if (args[0] === "registration-recover") {
      recovering = requestId!;
      throw new Error("owner_busy before recovery acceptance");
    }
    // The native owner has only the old claim. An exact B query returns null; a generic same-Reg query can see A.
    if (args[0] === "operation")
      return JSON.stringify(
        args.includes("--request-id")
          ? claim?.requestId === requestId
            ? claim
            : null
          : (claim ?? null)
      );
    return "null";
  });
  const service = await f.open(new AgentVMMCommandAdapter("/native/helper", run));
  await service.refresh();
  f.owner.inspect = async () => ({ status: "ready", workActivity: "idle" });
  f.owner.recoveryDescriptor = () => '{"registration_id":"reg-1"}';
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const earlier = service.state().currentRequest!.requestId;
  const state = service.state();
  await service.reauthorize({
    workspaceId: "workspace",
    registrationId: "reg-1",
    bindingRevision: state.bindingRevision!,
  });
  expect(service.state().currentRequest).toEqual({
    requestId: recovering,
    kind: "recover",
  });
  expect(recovering).not.toBe(earlier);
  await service.continue();
  expect(service.state().currentRequest?.requestId).toBe(recovering);
});

it("resolves an unknown authorization by the original request before exact removal", async () => {
  const f = await fixture(),
    authorized = deferred<{ registrationId: string; descriptor: string }>(),
    started = deferred<void>();
  let originalRequest = "";
  f.owner.authorize = async ({ requestId }) => {
    originalRequest = requestId;
    started.resolve();
    return authorized.promise;
  };
  f.owner.cancelRequest = vi.fn(async () => {
    throw new Error("cloud outcome remains unknown");
  });
  const service = await f.open();
  await service.refresh();
  const enabling = service.configure({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
  await started.promise;
  await service.remove();
  expect(f.owner.cancelRequest).toHaveBeenCalledWith({
    workspaceId: "workspace",
    requestId: originalRequest,
  });
  expect(service.state()).toMatchObject({
    status: "action_required",
    currentRequest: { kind: "remove" },
    desiredEnabled: false,
  });
  expect(f.adapter.remove).not.toHaveBeenCalled();
  f.owner.cancelRequest = vi.fn(async () => ({
    registrationId: "reg-1",
    hostBound: true,
  }));
  f.owner.inspect = async () => ({
    status: "removed",
    workActivity: "idle",
    hostBound: true,
  });
  await service.continue();
  expect(f.owner.cancelRequest).toHaveBeenCalledWith({
    workspaceId: "workspace",
    requestId: originalRequest,
  });
  expect(f.adapter.remove).toHaveBeenCalled();
  authorized.resolve({ registrationId: "reg-1", descriptor: "late secret" });
  await enabling;
  expect(service.state()).toMatchObject({
    status: "removed",
    currentRequest: { kind: "remove" },
  });
  expect(f.adapter.install).not.toHaveBeenCalled();
});

it("cancels a new enable during its first preparation without ever authorizing or invoking native", async () => {
  const f = await fixture(),
    prepared = deferred<void>(),
    preparing = deferred<void>();
  let canceledRequest = "";
  f.owner.inspectRequest = async () => {
    throw Object.assign(new Error("not found"), { status: 404 });
  };
  f.owner.cancelRequest = vi.fn(async ({ requestId }) => {
    canceledRequest = requestId;
    return { registrationId: "canceled-pending", hostBound: false };
  });
  f.adapter.observe = async () => ({
    host: "absent",
    connector: "absent",
    readability: "unreadable",
    salix: "unregistered",
    registration: "unreadable",
  });
  f.adapter.receipt = async () => {
    throw Object.assign(new Error("helper absent"), { code: "ENOENT" });
  };
  const service = await ComputeNodeService.open({
    filePath: f.filePath,
    adapter: f.adapter,
    installAuthorization: f.owner,
    platform: "darwin",
    arch: "arm64",
    clock: f.clock,
    preparation: {
      state: () => ({
        source: "download",
        location: "test bundle",
        instance: "shared",
        phase: "downloading",
      }),
      ensure: async () => {
        preparing.resolve();
        await prepared.promise;
      },
      rebuild: async () => {},
    },
  });
  await service.refresh();
  const enabling = service.configure({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
  await preparing.promise;
  const original = service.state().currentRequest!.requestId;
  await service.remove();
  expect(canceledRequest).toBe(original);
  expect(service.state()).toMatchObject({ status: "not_set", desiredEnabled: false });
  expect(service.state().currentRequest).toBeUndefined();
  prepared.resolve();
  await enabling;
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(f.adapter.install).not.toHaveBeenCalled();
  expect(f.adapter.remove).not.toHaveBeenCalled();
  expect(service.state().status).toBe("not_set");
});

it("does not infer native absence from a missing helper after restart", async () => {
  const f = await fixture();
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 1,
      desiredEnabled: true,
      workspaceId: "workspace",
      authorizationRequestId: "original-request",
      request: { requestId: "original-request", kind: "configure" },
    })
  );
  f.owner.cancelRequest = vi.fn(async () => ({
    registrationId: "reg-1",
    hostBound: false,
  }));
  f.adapter.observe = async () => ({
    host: "absent",
    connector: "absent",
    readability: "unreadable",
    salix: "unregistered",
    registration: "unreadable",
  });
  f.adapter.receipt = async () => {
    throw Object.assign(new Error("helper absent"), { code: "ENOENT" });
  };
  const reopened = await f.open();
  await reopened.refresh();
  await reopened.remove();
  expect(reopened.state().status).toBe("action_required");
  expect(reopened.state().currentRequest?.kind).toBe("remove");
});

it("pauses an unsubmitted preparation failure until explicit continuation, retaining unknown receipts after restart", async () => {
  const f = await fixture();
  const timers = new Set<() => void>();
  f.clock.setTimer = (_ms, run) => {
    timers.add(run);
    return () => timers.delete(run);
  };
  let phase: HostPreparationState["phase"] = "checking";
  const preparation = {
    state: (): HostPreparationState => ({
      source: "download",
      location: "test bundle",
      instance: "shared",
      phase,
    }),
    ensure: vi.fn(async (): Promise<void> => {
      phase = "failed";
      throw new Error("Host signature invalid");
    }),
    rebuild: async () => {},
  };
  f.adapter.receipt = vi.fn(async (requestId) => {
    if (phase !== "ready")
      throw Object.assign(new Error("helper absent"), { code: "ENOENT" });
    return f.receipts.get(requestId);
  });
  const open = () =>
    ComputeNodeService.open({
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
      preparation,
    });
  const service = await open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const request = service.state().currentRequest!.requestId;
  await service.refresh();
  expect(service.state()).toMatchObject({
    status: "action_required",
    problem: "setup_failed",
    problemDetail: "Host signature invalid",
    primaryAction: "continue",
    currentRequest: { requestId: request },
  });
  expect(timers.size).toBe(0);
  expect(preparation.ensure).toHaveBeenCalledTimes(1);
  expect(f.adapter.receipt).not.toHaveBeenCalled();
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(f.adapter.install).not.toHaveBeenCalled();

  const restarted = await open();
  await restarted.refresh();
  expect(restarted.state()).toMatchObject({
    status: "action_required",
    problem: "operation_unknown",
    primaryAction: "continue",
    operation: { outcome: "unknown" },
  });
  expect(timers.size).toBe(0);

  preparation.ensure.mockImplementation(async () => {
    phase = "ready";
  });
  await restarted.continue();
  expect(restarted.state()).toMatchObject({
    status: "ready",
    currentRequest: { requestId: request },
  });
  expect(preparation.ensure).toHaveBeenCalledTimes(2);
  expect(f.owner.authorize).toHaveBeenCalledTimes(1);
  expect(f.owner.authorize).toHaveBeenCalledWith({
    requestId: request,
    workspaceId: "workspace",
  });
  expect(f.adapter.install).toHaveBeenCalledWith(request, expect.any(String));
});

it("keeps an exact native owner fence separate from cloud authority until explicit disconnect and new setup", async () => {
  const f = await fixture();
  const helper = join(f.filePath + ".helper");
  const calls = join(f.filePath + ".calls");
  const proof = join(f.filePath + ".proof");
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 1,
      desiredEnabled: true,
      workspaceId: "workspace",
      registrationId: "reg-1",
      request: { requestId: "old-request", kind: "configure" },
      continuation: { deadlineAt: 999999 },
    })
  );
  await writeFile(
    proof,
    JSON.stringify({
      code: "request_blocked",
      reason: "local_owner_fence",
      requestId: "old-request",
    })
  );
  await writeFile(
    helper,
    `#!${process.execPath}
const fs = require('node:fs');
const args=process.argv.slice(2), command=args[0];
const file=${JSON.stringify(calls)};
const calls=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):[];
calls.push(command);fs.writeFileSync(file,JSON.stringify(calls));
if(command==='status') console.log(JSON.stringify({contractVersion:1,hostInstalled:true,hostLoaded:true,hostReadable:true,hostHealthy:true,registrationRead:'absent'}));
else if(command==='operation') { console.log(JSON.stringify({error:JSON.parse(fs.readFileSync(${JSON.stringify(proof)},'utf8'))}));process.exit(1); }
else { console.error('unexpected mutation');process.exit(1); }
`,
    { mode: 0o700 }
  );
  const ensure = vi.fn(async () => {});
  const timers = new Set<() => void>();
  const open = () =>
    ComputeNodeService.open({
      filePath: f.filePath,
      adapter: new AgentVMMCommandAdapter(helper),
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: {
        now: () => 1000,
        setTimer: (_delay, run) => {
          timers.add(run);
          return () => {
            timers.delete(run);
          };
        },
      },
      preparation: {
        ensure,
        rebuild: async () => {},
        state: () => ({
          phase: "ready",
          source: "download",
          location: "fixture",
          instance: "shared",
        }),
      },
    });
  const service = await open();
  await service.refresh();
  expect(service.state()).toMatchObject({
    status: "action_required",
    problem: "request_blocked",
    primaryAction: "remove",
    bindingRegistrationId: "reg-1",
    currentRequest: { requestId: "old-request" },
    operation: { outcome: "unknown" },
  });
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  await service.continue();
  service.networkRecovered();
  const reopened = await open();
  await reopened.refresh();
  expect(reopened.state().problem).toBe("request_blocked");
  expect(timers.size).toBe(0);
  expect(JSON.parse(await readFile(f.filePath, "utf8")).continuation).toBeUndefined();
  expect(ensure).not.toHaveBeenCalled();
  for (const method of ["authorize", "retry", "configure", "revoke"] as const)
    expect(f.owner[method]).not.toHaveBeenCalled();
  expect(
    (JSON.parse(await readFile(calls, "utf8")) as string[]).every((x) =>
      ["status", "operation"].includes(x)
    )
  ).toBe(true);

  for (const negative of [
    {
      code: "request_blocked",
      reason: "local_owner_fence",
      requestId: "other-request",
    },
    { code: "request_blocked", requestId: "old-request" },
  ]) {
    await writeFile(proof, JSON.stringify(negative));
    const unknown = await open();
    await unknown.refresh();
    expect(unknown.state()).toMatchObject({
      problem: "operation_unknown",
      primaryAction: "continue",
    });
    await unknown.continue();
    expect(unknown.state().problem).toBe("operation_unknown");
  }
  for (const method of ["authorize", "retry", "configure", "revoke"] as const)
    expect(f.owner[method]).not.toHaveBeenCalled();

  // Explicit disconnect uses its own exact scope. It does not need the old request's missing target proof.
  const removal = await f.open();
  await removal.refresh();
  await removal.remove();
  expect(removal.state().status).toBe("removed");
  expect(f.owner.revoke).toHaveBeenCalledWith({
    workspaceId: "workspace",
    registrationId: "reg-1",
  });
  expect(f.adapter.remove).toHaveBeenCalledWith(
    expect.not.stringMatching(/^old-request$/),
    "reg-1"
  );
  await removal.configure({ desiredEnabled: true, workspaceId: "workspace" });
  expect(f.owner.authorize).toHaveBeenCalledWith({
    workspaceId: "workspace",
    requestId: expect.not.stringMatching(/^old-request$/),
  });
});

it("observes settled legacy installs without requesting root recovery or replay", async () => {
  const f = await fixture(),
    service = await f.open();
  await service.refresh();
  await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
  const id = service.state().currentRequest!.requestId;
  for (const outcome of ["succeeded", "superseded"] as const) {
    f.receipts.set(id, {
      requestId: id,
      targetRegistrationId: "reg-1",
      kind: "install-managed",
      outcome,
    });
    await service.continue();
    expect(service.state().primaryAction).not.toBe("recover");
    expect(f.adapter.resume).not.toHaveBeenCalled();
    expect(f.adapter.enable).not.toHaveBeenCalled();
    expect(f.owner.retry).not.toHaveBeenCalled();
  }
});

async function refusedClaim(code = "invalid_ticket") {
  const f = await fixture();
  const requestId = "saved-claim-request";
  const helper = f.filePath + ".helper";
  const nativeFile = f.filePath + ".native";
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 1,
      desiredEnabled: true,
      workspaceId: "workspace",
      registrationId: "reg-1",
      request: { requestId, kind: "configure" },
      continuation: { deadlineAt: 100000 },
    })
  );
  await writeFile(
    nativeFile,
    JSON.stringify({
      calls: [],
      receipt: {
        requestId,
        targetRegistrationId: "reg-1",
        kind: "registration-claim",
        outcome: "failed",
        failureCode: code,
        retryable: false,
      },
    })
  );
  await writeFile(
    helper,
    `#!${process.execPath}
const fs=require('node:fs'), file=${JSON.stringify(nativeFile)};
const state=JSON.parse(fs.readFileSync(file,'utf8')), args=process.argv.slice(2), command=args[0];
const requestId=args[args.indexOf('--request-id')+1];
state.calls.push({command,requestId,descriptor:args.includes('--descriptor-stdin')});
let result;
if(command==='operation') result=state.unreadable?{invalid:'receipt'}:state.receipt;
else if(command==='status') result={contractVersion:1,hostInstalled:true,hostLoaded:true,hostReadable:true,hostHealthy:true,connectorLoaded:state.receipt.outcome==='succeeded',registrationRead:state.receipt.outcome==='succeeded'?'present':'absent'};
else if(command==='registration-claim') {
 if(args.includes('--descriptor-stdin')) {const descriptor=JSON.parse(fs.readFileSync(0,'utf8'));if(descriptor.registration_id!=='reg-1'||descriptor.ticket!=='new-ticket')throw new Error('wrong descriptor');}
 state.receipt={requestId,targetRegistrationId:'reg-1',kind:'registration-claim',outcome:'succeeded'};
 result=state.receipt;
} else throw new Error('unexpected mutation '+command);
fs.writeFileSync(file,JSON.stringify(state));process.stdout.write(JSON.stringify(result));
`,
    { mode: 0o700 }
  );
  f.owner.retry = vi.fn(async () => ({
    registrationId: "reg-1",
    descriptor: '{"registration_id":"reg-1","ticket":"new-ticket"}',
  }));
  const timers = new Set<() => void>();
  const service = await ComputeNodeService.open({
    filePath: f.filePath,
    adapter: new AgentVMMCommandAdapter(helper),
    installAuthorization: f.owner,
    platform: "darwin",
    arch: "arm64",
    clock: {
      now: () => 1000,
      setTimer: (_ms, run) => {
        timers.add(run);
        return () => {
          timers.delete(run);
        };
      },
    },
  });
  const native = async () =>
    JSON.parse(await readFile(nativeFile, "utf8")) as {
      calls: { command: string; requestId: string; descriptor: boolean }[];
      receipt: NativeRequestReceipt;
      unreadable?: boolean;
    };
  return { ...f, service, requestId, native, nativeFile, timers };
}

it("renews a refused first claim ticket only on explicit continuation through the original native request", async () => {
  for (const code of ["invalid_ticket", "ticket_expired"]) {
    const f = await refusedClaim(code);
    await f.service.refresh();
    expect(f.service.state()).toMatchObject({
      operation: { outcome: "failed" },
      currentRequest: { requestId: f.requestId },
    });
    const primaryAction = f.service.state().primaryAction;
    f.service.networkRecovered();
    expect(f.timers.size).toBe(0);
    expect(f.owner.retry).not.toHaveBeenCalled();
    await f.service.continue();
    expect(f.owner.retry).toHaveBeenCalledWith({
      workspaceId: "workspace",
      registrationId: "reg-1",
    });
    expect(primaryAction).toBe("continue");
    expect(f.service.state().operation?.outcome).toBe("succeeded");
    expect(f.service.state().currentRequest?.requestId).toBe(f.requestId);
    const native = await f.native();
    expect(native.calls.filter((x) => x.command === "registration-claim")).toEqual([
      { command: "registration-claim", requestId: f.requestId, descriptor: true },
    ]);
    await f.service.continue();
    await f.service.refresh();
    expect(f.owner.retry).toHaveBeenCalledTimes(1);
    expect(
      (await f.native()).calls.filter((x) => x.command === "registration-claim")
    ).toHaveLength(1);
    expect(f.owner.authorize).not.toHaveBeenCalled();
    expect(f.owner.configure).not.toHaveBeenCalled();
    expect(f.owner.revoke).not.toHaveBeenCalled();
  }
});

it("resumes only the original candidate when the server explicitly refuses ticket renewal and preserves other failures", async () => {
  for (const error of [
    new ComputeNodeTicketNotRetryableError({
      code: "registration_not_retryable",
      status: 409,
    }),
    new Error("registration revoked"),
    new Error("retry outcome unknown"),
  ]) {
    const f = await refusedClaim();
    f.owner.retry = vi.fn(async () => {
      throw error;
    });
    await f.service.refresh();
    await f.service.continue();
    expect(f.owner.retry).toHaveBeenCalledTimes(1);
    const claims = (await f.native()).calls.filter(
      (x) => x.command === "registration-claim"
    );
    expect(claims).toEqual(
      error instanceof ComputeNodeTicketNotRetryableError
        ? [{ command: "registration-claim", requestId: f.requestId, descriptor: false }]
        : []
    );
    expect(f.service.state().currentRequest?.requestId).toBe(f.requestId);
    expect(f.service.state().bindingRegistrationId).toBe("reg-1");
    expect(f.owner.authorize).not.toHaveBeenCalled();
    expect(f.owner.configure).not.toHaveBeenCalled();
    expect(f.owner.revoke).not.toHaveBeenCalled();
  }
});

it("does not renew a claim ticket when its receipt is unreadable", async () => {
  const f = await refusedClaim();
  const native = await f.native();
  await writeFile(f.nativeFile, JSON.stringify({ ...native, unreadable: true }));
  await f.service.refresh();
  await f.service.continue();
  expect(f.service.state().problem).toBe("operation_unknown");
  expect(f.owner.retry).not.toHaveBeenCalled();
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(
    (await f.native()).calls.filter((x) => x.command === "registration-claim")
  ).toEqual([]);
});

it("does not rotate a ticket during automatic continuation of a retryable claim", async () => {
  const f = await refusedClaim();
  const native = await f.native();
  native.receipt.retryable = true;
  await writeFile(f.nativeFile, JSON.stringify(native));
  await f.service.refresh();
  const run = [...f.timers][0];
  expect(run).toBeDefined();
  f.timers.clear();
  run!();
  await f.service.refresh();
  expect(f.owner.retry).not.toHaveBeenCalled();
  expect(
    (await f.native()).calls.filter((x) => x.command === "registration-claim")
  ).toEqual([
    { command: "registration-claim", requestId: f.requestId, descriptor: false },
  ]);
});

/** A node with a saved claim and Registration, read through the real adapter at a helper path the test controls. */
async function savedNode(helper: "missing" | "failing") {
  const f = await fixture();
  const helperPath = join(f.filePath + ".host", "agent-vmm-lifecycle");
  if (helper === "failing") {
    await mkdir(dirname(helperPath), { recursive: true });
    await writeFile(helperPath, "#!/bin/sh\nexit 1\n", { mode: 0o700 });
  }
  const intent = {
    version: 5,
    revision: 1,
    desiredEnabled: true,
    workspaceId: "workspace",
    registrationId: "reg-1",
    authorizationRequestId: "claim-1",
    request: { requestId: "claim-1", kind: "configure" },
    continuation: { deadlineAt: 1000 + 45 * 60_000 },
  };
  await writeFile(f.filePath, JSON.stringify(intent));
  const timers = new Set<() => void>();
  const service = await ComputeNodeService.open({
    filePath: f.filePath,
    adapter: new AgentVMMCommandAdapter(helperPath),
    installAuthorization: f.owner,
    platform: "darwin",
    arch: "arm64",
    clock: {
      now: () => 1000,
      setTimer: (_delay, run) => {
        timers.add(run);
        return () => {
          timers.delete(run);
        };
      },
    },
    hostInstallation: async () => "not_installed",
  });
  await service.refresh();
  return { ...f, service, timers, intent };
}

it("shows an uninstalled Host as uninstalled with Reinstall and keeps the saved request and Registration", async () => {
  const f = await savedNode("missing");
  expect(f.service.state()).toMatchObject({
    status: "action_required",
    problem: "host_uninstalled",
    primaryAction: "update_host",
    observed: { host: "absent" },
    facets: { installationHealth: "absent" },
    currentRequest: { requestId: "claim-1", kind: "configure" },
    bindingRegistrationId: "reg-1",
  });
  expect(f.timers.size).toBe(0);
  const saved = JSON.parse(await readFile(f.filePath, "utf8"));
  expect(saved).toMatchObject({
    registrationId: "reg-1",
    authorizationRequestId: "claim-1",
    request: f.intent.request,
  });
  expect(f.owner.authorize).not.toHaveBeenCalled();
  expect(f.owner.retry).not.toHaveBeenCalled();
});

it("keeps a helper that exists but cannot be read as an unknown operation", async () => {
  const f = await savedNode("failing");
  expect(f.service.state()).toMatchObject({
    status: "action_required",
    problem: "operation_unknown",
    primaryAction: "continue",
  });
});

it("refreshes the node after a successful uninstall so it shows the uninstalled Host at once", async () => {
  const f = await fixture();
  let installation: "installed" | "not_installed" = "installed";
  const uninstalled = {
    installation: "not_installed" as const,
    updateAvailable: false,
    operation: {
      requestId: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
      action: "uninstall" as const,
      dataPolicy: "preserve" as const,
      phase: "completed" as const,
      outcome: "succeeded" as const,
    },
  };
  let settled: ((state: typeof uninstalled) => void) | undefined;
  const maintenance = {
    onHostReset: () => () => {},
    onSettled: (listener: typeof settled) => {
      settled = listener;
      return () => {};
    },
    continuePending: async () => false,
    state: async () => ({ installation, updateAvailable: false }),
    maintain: async () => {
      installation = "not_installed";
      // Like the real maintenance, its listeners hear the success before the call returns.
      settled?.(uninstalled);
      return uninstalled;
    },
  } as unknown as LocalHostMaintenance;
  const hostUninstalled = vi.spyOn(ComputeNodeService.prototype, "hostUninstalled");
  const shown = deferred<void>();
  const session = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account", email: "account@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const account = new AccountComputeNodeService(
    {
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
      onStateChanged: (state) => {
        if (state.problem === "host_uninstalled") shown.resolve();
      },
    },
    session,
    undefined,
    maintenance
  );
  await account.configure({ desiredEnabled: true, workspaceId: "workspace" });
  expect(account.state().status).toBe("ready");
  f.adapter.observe = async () => ({
    host: "ready",
    connector: "ready",
    readability: "unreadable",
    salix: "unregistered",
    registration: "unreadable",
    reason: "helper_missing",
  });
  f.adapter.receipt = async () => {
    throw Object.assign(new Error("helper absent"), { code: "ENOENT" });
  };
  await account.maintainHost({ action: "uninstall", dataPolicy: "preserve" });
  await shown.promise;
  expect(account.state()).toMatchObject({
    status: "action_required",
    problem: "host_uninstalled",
    primaryAction: "update_host",
    observed: { host: "absent" },
  });
  expect(hostUninstalled).toHaveBeenCalledTimes(1);
});

it("shows an uninstall and a reinstall that succeed on a background retry on the node", async () => {
  const f = await fixture();
  let settled: ((state: HostMaintenanceState) => void) | undefined;
  let installation: HostMaintenanceState["installation"] = "installed";
  const maintenance = {
    onHostReset: () => () => {},
    onSettled: (listener: typeof settled) => {
      settled = listener;
      return () => {};
    },
    continuePending: async () => true,
    state: async () => ({ installation, updateAvailable: false }),
  } as unknown as LocalHostMaintenance;
  const hostUninstalled = vi.spyOn(ComputeNodeService.prototype, "hostUninstalled");
  const hostReinstalled = vi.spyOn(ComputeNodeService.prototype, "hostReinstalled");
  const session = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account", email: "account@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const account = new AccountComputeNodeService(
    {
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
    },
    session,
    undefined,
    maintenance
  );
  await account.configure({ desiredEnabled: true, workspaceId: "workspace" });
  expect(account.state().status).toBe("ready");
  const observe = f.adapter.observe,
    receipt = f.adapter.receipt;
  f.adapter.observe = async () => ({
    host: "ready",
    connector: "ready",
    readability: "unreadable",
    salix: "unregistered",
    registration: "unreadable",
    reason: "helper_missing",
  });
  f.adapter.receipt = async () => {
    throw Object.assign(new Error("helper absent"), { code: "ENOENT" });
  };
  const succeeded = (requestId: string, action: "uninstall" | "reinstall") => ({
    installation,
    updateAvailable: false,
    operation: {
      requestId,
      action,
      dataPolicy: "preserve" as const,
      phase: "completed" as const,
      outcome: "succeeded" as const,
    },
  });
  // The first try failed and returned; the retry timer later settles the same request.
  installation = "not_installed";
  settled!(succeeded("aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", "uninstall"));
  // The refresh queues behind the one the settled uninstall started.
  await account.refresh();
  expect(account.state()).toMatchObject({
    status: "action_required",
    problem: "host_uninstalled",
    observed: { host: "absent" },
  });
  expect(hostUninstalled).toHaveBeenCalledTimes(1);

  f.adapter.observe = observe;
  if (receipt) f.adapter.receipt = receipt;
  else delete f.adapter.receipt;
  installation = "installed";
  settled!(succeeded("bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb", "reinstall"));
  await account.refresh();
  expect(account.state()).toMatchObject({ status: "ready" });
  expect(hostReinstalled).toHaveBeenCalledTimes(1);
});

it("parses optional dataEpoch, deviceId, and deviceIdentityState from lifecycle status without failing on older helpers", async () => {
  const newAdapter = new AgentVMMCommandAdapter("helper", async () =>
    JSON.stringify({
      contractVersion: 1,
      hostInstalled: true,
      hostLoaded: true,
      hostReadable: true,
      hostHealthy: true,
      connectorInstalled: true,
      connectorLoaded: true,
      registrationRead: "present",
      registrationState: "enabled",
      dataEpoch: 3,
      deviceId: "dev-mac-a",
      deviceIdentityState: "ready",
    })
  );
  await expect(newAdapter.observe("reg-1")).resolves.toMatchObject({
    dataEpoch: 3,
    deviceId: "dev-mac-a",
    deviceIdentityState: "ready",
    registration: "present",
  });

  const legacyAdapter = new AgentVMMCommandAdapter("helper", async () =>
    JSON.stringify({
      contractVersion: 1,
      hostInstalled: true,
      hostLoaded: true,
      hostReadable: true,
      hostHealthy: true,
      connectorInstalled: false,
      connectorLoaded: false,
      registrationRead: "absent",
    })
  );
  const legacy = await legacyAdapter.observe("reg-1");
  expect(legacy.readability).toBe("readable");
  expect(legacy.dataEpoch).toBeUndefined();
  expect(legacy.deviceId).toBeUndefined();
  expect(legacy.deviceIdentityState).toBeUndefined();
});

it("never falls into continuation_paused when local registration is absent and remote hostBound is true", async () => {
  const f = await fixture();
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 2,
      desiredEnabled: true,
      workspaceId: "workspace",
      registrationId: "reg-bound",
      request: { requestId: "req-bound", kind: "configure" },
      continuation: { deadlineAt: 500 },
    })
  );
  vi.mocked(f.owner.inspect).mockResolvedValue({
    status: "stopped",
    hostBound: true,
    deviceId: "dev-original",
    connected: false,
    workActivity: "idle",
  });
  vi.mocked(f.adapter.observe).mockResolvedValue({
    host: "ready",
    connector: "absent",
    readability: "readable",
    salix: "unregistered",
    registration: "absent",
    deviceId: "dev-new",
    deviceIdentityState: "ready",
  });
  const service = await f.open();
  const observed = await service.refresh();
  expect(observed.status).toBe("action_required");
  expect(observed.problem).toBe("authorization_attention");
  expect(f.owner.retry).not.toHaveBeenCalled();
});

it("routes absent local registration deterministically across retry (A), recover (B), confirmed local rebind (C1), and cross-machine protection (C2)", async () => {
  // Branch A: remote.hostBound === false && status !== removed -> owner.retry + adapter.install
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-1",
      })
    );
    vi.mocked(f.owner.inspect).mockResolvedValue({
      status: "processing",
      hostBound: false,
      workActivity: "idle",
    });
    const service = await f.open();
    await service.configure({ desiredEnabled: true, workspaceId: "workspace" });
    expect(f.owner.retry).toHaveBeenCalledTimes(1);
    expect(f.adapter.install).toHaveBeenCalledTimes(1);
    expect(f.owner.revoke).not.toHaveBeenCalled();
  }

  // Branch B: remote.hostBound === true && same deviceId && deviceIdentityState === ready -> recover
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-1",
      })
    );
    let recovered = false;
    f.owner.recoveryDescriptor = vi.fn(() => '{"registration_id":"reg-1"}');
    f.adapter.recover = vi.fn(async (requestId) => {
      recovered = true;
      const receipt: NativeRequestReceipt = {
        requestId,
        targetRegistrationId: "reg-1",
        kind: "registration-recover",
        outcome: "succeeded",
      };
      f.receipts.set(requestId, receipt);
      return receipt;
    });
    vi.mocked(f.owner.inspect).mockImplementation(async () => ({
      status: recovered ? "ready" : "action_required",
      hostBound: true,
      deviceId: "dev-same",
      connected: recovered,
      workActivity: "idle",
    }));
    vi.mocked(f.adapter.observe).mockImplementation(async () => ({
      host: "ready",
      connector: recovered ? "ready" : "absent",
      readability: "readable",
      salix: "unregistered",
      registration: recovered ? "present" : "absent",
      deviceId: "dev-same",
      deviceIdentityState: "ready",
    }));
    const service = await f.open();
    const state = await service.configure({
      desiredEnabled: true,
      workspaceId: "workspace",
    });
    expect(f.owner.recoveryDescriptor).toHaveBeenCalledTimes(1);
    expect(f.adapter.recover).toHaveBeenCalledTimes(1);
    expect(f.owner.retry).not.toHaveBeenCalled();
    expect(f.owner.revoke).not.toHaveBeenCalled();
    expect(state.status).toBe("ready");
  }

  // Branch C1: local hostDataReset() or boundDeviceId match + remote.connected === false -> revoke -> save -> authorize -> install
  {
    const f = await fixture();
    const events: string[] = [];
    let currentReg = "reg-old";
    let present = true;
    let localDeviceId = "dev-before-reset";
    vi.mocked(f.owner.inspect).mockImplementation(async ({ registrationId }) => ({
      status: registrationId === "reg-new" ? "ready" : "action_required",
      hostBound: true,
      deviceId: registrationId === "reg-new" ? "dev-after-reset" : "dev-before-reset",
      connected: registrationId === "reg-new",
      workActivity: "idle",
    }));
    vi.mocked(f.adapter.observe).mockImplementation(async () => ({
      host: "ready",
      connector: present ? "ready" : "absent",
      readability: "readable",
      salix: "unregistered",
      registration: present ? "present" : "absent",
      deviceId: localDeviceId,
      deviceIdentityState: "ready",
    }));
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-old",
      })
    );
    const service = await f.open();
    // Observe present once so boundDeviceId is persisted.
    await service.refresh();
    const afterPresent = JSON.parse(await readFile(f.filePath, "utf8"));
    expect(afterPresent.boundDeviceId).toBe("dev-before-reset");

    // Simulate Host data reset: local registration absent, new deviceId.
    present = false;
    localDeviceId = "dev-after-reset";
    await service.hostDataReset();
    const afterReset = JSON.parse(await readFile(f.filePath, "utf8"));
    expect(afterReset.resetPendingRebind).toBe(true);

    vi.mocked(f.owner.revoke).mockImplementation(async ({ registrationId }) => {
      events.push(`revoke:${registrationId}`);
      return "removed";
    });
    vi.mocked(f.owner.authorize).mockImplementation(async ({ requestId }) => {
      // Verify old registrationId was cleared and new authorizationRequestId was persisted before authorize.
      const savedBeforeAuthorize = JSON.parse(await readFile(f.filePath, "utf8"));
      expect(savedBeforeAuthorize.registrationId).toBeUndefined();
      expect(savedBeforeAuthorize.resetPendingRebind).toBeUndefined();
      expect(savedBeforeAuthorize.authorizationRequestId).toBe(requestId);
      events.push("authorize");
      currentReg = "reg-new";
      return {
        registrationId: "reg-new",
        descriptor: '{"registration_id":"reg-new"}',
      };
    });
    vi.mocked(f.adapter.install).mockImplementation(async (requestId) => {
      events.push("install");
      present = true;
      const receipt: NativeRequestReceipt = {
        requestId: requestId!,
        targetRegistrationId: currentReg,
        kind: "registration-claim",
        outcome: "succeeded",
      };
      f.receipts.set(requestId!, receipt);
      return receipt;
    });

    const rebound = await service.configure({
      desiredEnabled: true,
      workspaceId: "workspace",
    });
    expect(events).toEqual(["revoke:reg-old", "authorize", "install"]);
    expect(rebound.status).toBe("ready");
    expect(rebound.bindingRegistrationId).toBe("reg-new");
    const afterRebind = JSON.parse(await readFile(f.filePath, "utf8"));
    expect(afterRebind.boundDeviceId).toBe("dev-after-reset");
    expect(afterRebind.resetPendingRebind).toBeUndefined();
  }

  // Branch C2a: Migration Assistant copied userData to another Mac while original Mac is still connected -> NEVER revoke
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-live-other-mac",
        boundDeviceId: "dev-original-mac",
        resetPendingRebind: true,
      })
    );
    vi.mocked(f.owner.inspect).mockResolvedValue({
      status: "ready",
      hostBound: true,
      deviceId: "dev-original-mac",
      connected: true,
      workActivity: "idle",
    });
    vi.mocked(f.adapter.observe).mockResolvedValue({
      host: "ready",
      connector: "absent",
      readability: "readable",
      salix: "unregistered",
      registration: "absent",
      deviceId: "dev-migrated-mac",
      deviceIdentityState: "ready",
    });
    const service = await f.open();
    const state = await service.configure({
      desiredEnabled: true,
      workspaceId: "workspace",
    });
    expect(f.owner.revoke).not.toHaveBeenCalled();
    expect(f.owner.authorize).not.toHaveBeenCalled();
    expect(state.status).toBe("action_required");
    expect(state.problem).toBe("authorization_attention");
  }

  // Branch C2b: Missing remote.deviceId and no resetPendingRebind -> NEVER revoke
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-legacy",
      })
    );
    vi.mocked(f.owner.inspect).mockResolvedValue({
      status: "action_required",
      hostBound: true,
      connected: false,
      workActivity: "idle",
    });
    vi.mocked(f.adapter.observe).mockResolvedValue({
      host: "ready",
      connector: "absent",
      readability: "readable",
      salix: "unregistered",
      registration: "absent",
      deviceId: "dev-mac-x",
      deviceIdentityState: "ready",
    });
    const service = await f.open();
    const state = await service.configure({
      desiredEnabled: true,
      workspaceId: "workspace",
    });
    expect(f.owner.revoke).not.toHaveBeenCalled();
    expect(f.owner.authorize).not.toHaveBeenCalled();
    expect(state.status).toBe("action_required");
    expect(state.problem).toBe("authorization_attention");
    expect(state.primaryAction).toBe("recover");
  }
});

it("replaces a fenced old request on hostDataReset so Continue completes revoke -> authorize -> install in one step", async () => {
  const f = await fixture();
  const oldBlockedId = "22222222-2222-4222-8222-222222222222";
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 3,
      desiredEnabled: true,
      workspaceId: "workspace",
      registrationId: "reg-old",
      boundDeviceId: "dev-old",
      request: { requestId: oldBlockedId, kind: "configure" },
    })
  );
  let present = false;
  let currentReg = "reg-old";
  const events: string[] = [];
  vi.mocked(f.adapter.receipt!).mockImplementation(async (requestId) => {
    if (requestId === oldBlockedId) {
      throw new ComputeNodeCommandError("request fenced by reset", "command_failed", {
        code: "request_blocked",
        reason: "local_owner_fence",
        requestId: oldBlockedId,
      });
    }
    return f.receipts.get(requestId);
  });
  vi.mocked(f.adapter.observe).mockImplementation(async () => ({
    host: "ready",
    connector: present ? "ready" : "absent",
    readability: "readable",
    salix: "unregistered",
    registration: present ? "present" : "absent",
    deviceId: "dev-after-reset",
    deviceIdentityState: "ready",
  }));
  vi.mocked(f.owner.inspect).mockImplementation(async ({ registrationId }) => ({
    status: registrationId === "reg-new" ? "ready" : "action_required",
    hostBound: true,
    deviceId: registrationId === "reg-new" ? "dev-after-reset" : "dev-old",
    connected: registrationId === "reg-new",
    workActivity: "idle",
  }));
  vi.mocked(f.owner.revoke).mockImplementation(async ({ registrationId }) => {
    events.push(`revoke:${registrationId}`);
    return "removed";
  });
  vi.mocked(f.owner.authorize).mockImplementation(async () => {
    events.push("authorize");
    currentReg = "reg-new";
    return { registrationId: "reg-new", descriptor: '{"registration_id":"reg-new"}' };
  });
  vi.mocked(f.adapter.install).mockImplementation(async (requestId) => {
    events.push("install");
    present = true;
    const receipt: NativeRequestReceipt = {
      requestId: requestId!,
      targetRegistrationId: currentReg,
      kind: "registration-claim",
      outcome: "succeeded",
    };
    f.receipts.set(requestId!, receipt);
    return receipt;
  });

  const service = await f.open();
  const afterReset = await service.hostDataReset();
  expect(afterReset.status).toBe("action_required");
  expect(afterReset.problem).toBe("continuation_paused");
  expect(afterReset.primaryAction).toBe("continue");
  expect(afterReset.currentRequest?.requestId).not.toBe(oldBlockedId);

  const converged = await service.continue();
  expect(events).toEqual(["revoke:reg-old", "authorize", "install"]);
  expect(converged.status).toBe("ready");
  expect(converged.bindingRegistrationId).toBe("reg-new");
});

it("offers Continue (not recover) when manual wipe satisfies confirmedLocalReset and converges on continue()", async () => {
  const f = await fixture();
  await writeFile(
    f.filePath,
    JSON.stringify({
      version: 5,
      revision: 2,
      desiredEnabled: true,
      workspaceId: "workspace",
      registrationId: "reg-old",
      boundDeviceId: "dev-before-wipe",
    })
  );
  let present = false;
  let currentReg = "reg-old";
  const events: string[] = [];
  vi.mocked(f.adapter.observe).mockImplementation(async () => ({
    host: "ready",
    connector: present ? "ready" : "absent",
    readability: "readable",
    salix: "unregistered",
    registration: present ? "present" : "absent",
    deviceId: "dev-after-wipe",
    deviceIdentityState: "ready",
  }));
  vi.mocked(f.owner.inspect).mockImplementation(async ({ registrationId }) => ({
    status: registrationId === "reg-new" ? "ready" : "action_required",
    hostBound: true,
    deviceId: registrationId === "reg-new" ? "dev-after-wipe" : "dev-before-wipe",
    connected: registrationId === "reg-new",
    workActivity: "idle",
  }));
  vi.mocked(f.owner.revoke).mockImplementation(async ({ registrationId }) => {
    events.push(`revoke:${registrationId}`);
    return "removed";
  });
  vi.mocked(f.owner.authorize).mockImplementation(async () => {
    events.push("authorize");
    currentReg = "reg-new";
    return { registrationId: "reg-new", descriptor: '{"registration_id":"reg-new"}' };
  });
  vi.mocked(f.adapter.install).mockImplementation(async (requestId) => {
    events.push("install");
    present = true;
    const receipt: NativeRequestReceipt = {
      requestId: requestId!,
      targetRegistrationId: currentReg,
      kind: "registration-claim",
      outcome: "succeeded",
    };
    f.receipts.set(requestId!, receipt);
    return receipt;
  });

  const service = await f.open();
  const observed = await service.refresh();
  expect(observed.status).toBe("action_required");
  expect(observed.problem).toBe("continuation_paused");
  expect(observed.primaryAction).toBe("continue");

  const converged = await service.continue();
  expect(events).toEqual(["revoke:reg-old", "authorize", "install"]);
  expect(converged.status).toBe("ready");
  expect(converged.bindingRegistrationId).toBe("reg-new");
});

it("offers remove (not doomed recover) for C2 identity mismatch while preserving recover when remote deviceId is absent", async () => {
  // C2a: connected === true on original Mac with mismatched deviceId -> primaryAction = "remove"
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-live",
        boundDeviceId: "dev-origin",
        resetPendingRebind: true,
      })
    );
    vi.mocked(f.owner.inspect).mockResolvedValue({
      status: "ready",
      hostBound: true,
      deviceId: "dev-origin",
      connected: true,
      workActivity: "idle",
    });
    vi.mocked(f.adapter.observe).mockResolvedValue({
      host: "ready",
      connector: "absent",
      readability: "readable",
      salix: "unregistered",
      registration: "absent",
      deviceId: "dev-migrated",
      deviceIdentityState: "ready",
    });
    const service = await f.open();
    const observed = await service.refresh();
    expect(observed.status).toBe("action_required");
    expect(observed.problem).toBe("authorization_attention");
    expect(observed.primaryAction).toBe("remove");
  }

  // C2b: connected === false, mismatched deviceId, but no boundDeviceId / resetPendingRebind -> primaryAction = "remove"
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-untracked",
      })
    );
    vi.mocked(f.owner.inspect).mockResolvedValue({
      status: "action_required",
      hostBound: true,
      deviceId: "dev-origin",
      connected: false,
      workActivity: "idle",
    });
    vi.mocked(f.adapter.observe).mockResolvedValue({
      host: "ready",
      connector: "absent",
      readability: "readable",
      salix: "unregistered",
      registration: "absent",
      deviceId: "dev-other",
      deviceIdentityState: "ready",
    });
    const service = await f.open();
    const observed = await service.refresh();
    expect(observed.status).toBe("action_required");
    expect(observed.problem).toBe("authorization_attention");
    expect(observed.primaryAction).toBe("remove");
  }

  // Legacy server without remote.deviceId -> primaryAction = "recover" remains backwards-compatible
  {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 5,
        revision: 1,
        desiredEnabled: true,
        workspaceId: "workspace",
        registrationId: "reg-legacy",
      })
    );
    vi.mocked(f.owner.inspect).mockResolvedValue({
      status: "action_required",
      hostBound: true,
      connected: false,
      workActivity: "idle",
    });
    vi.mocked(f.adapter.observe).mockResolvedValue({
      host: "ready",
      connector: "absent",
      readability: "readable",
      salix: "unregistered",
      registration: "absent",
      deviceId: "dev-local",
      deviceIdentityState: "ready",
    });
    const service = await f.open();
    const observed = await service.refresh();
    expect(observed.status).toBe("action_required");
    expect(observed.problem).toBe("authorization_attention");
    expect(observed.primaryAction).toBe("recover");
  }
});

it("silently runs automaticUpdate once per release pair when enabled and idle, and resumes node after update", async () => {
  const f = await fixture();
  let maintenanceState: HostMaintenanceState = {
    installation: "installed",
    installedReleaseId: "old-release",
    selectedReleaseId: "new-release",
    updateAvailable: true,
  };
  const automaticUpdate = vi.fn(async (): Promise<HostMaintenanceState> => {
    maintenanceState = {
      installation: "installed",
      installedReleaseId: "new-release",
      selectedReleaseId: "new-release",
      updateAvailable: false,
      operation: {
        requestId: "cccccccc-cccc-4ccc-cccc-cccccccccccc",
        action: "update",
        dataPolicy: "preserve",
        phase: "completed",
        outcome: "succeeded",
      },
    };
    return maintenanceState;
  });
  const maintenance = {
    onHostReset: () => () => {},
    onSettled: () => () => {},
    continuePending: async () => false,
    state: async () => maintenanceState,
    automaticUpdate,
  } as unknown as LocalHostMaintenance;
  const hostReinstalled = vi.spyOn(ComputeNodeService.prototype, "hostReinstalled");
  const session = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account", email: "account@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const account = new AccountComputeNodeService(
    {
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
    },
    session,
    undefined,
    maintenance
  );
  // Before enabling, silent auto-update does not run.
  await account.hostMaintenanceState();
  expect(automaticUpdate).not.toHaveBeenCalled();

  await account.configure({ desiredEnabled: true, workspaceId: "workspace" });
  await account.refresh();
  await account.hostMaintenanceState();
  expect(automaticUpdate).toHaveBeenCalledTimes(1);
  expect(hostReinstalled).toHaveBeenCalledTimes(1);

  // Repeated refreshes for the same release pair do not loop.
  maintenanceState = {
    installation: "installed",
    installedReleaseId: "old-release",
    selectedReleaseId: "new-release",
    updateAvailable: true,
  };
  await account.refresh();
  expect(automaticUpdate).toHaveBeenCalledTimes(1);
});

it("automatically reconfigures back to ready after a reset reinstall when previously enabled", async () => {
  const f = await fixture();
  let present = false;
  let currentReg = "reg-1";
  let deviceId = "dev-before";
  let remoteConnected = false;
  const events: string[] = [];
  vi.mocked(f.adapter.observe).mockImplementation(async () => ({
    host: "ready",
    connector: present ? "ready" : "absent",
    readability: "readable",
    salix: present ? "ready" : "unregistered",
    registration: present ? "present" : "absent",
    deviceId,
    deviceIdentityState: "ready",
  }));
  vi.mocked(f.owner.inspect).mockImplementation(async ({ registrationId }) => ({
    status: registrationId === currentReg && present ? "ready" : "action_required",
    hostBound: true,
    deviceId: registrationId === "reg-1" ? "dev-before" : "dev-after",
    connected: registrationId === currentReg && remoteConnected,
    workActivity: "idle",
  }));
  vi.mocked(f.owner.revoke).mockImplementation(async ({ registrationId }) => {
    events.push(`revoke:${registrationId}`);
    return "removed";
  });
  vi.mocked(f.owner.authorize).mockImplementation(async () => {
    const nextReg = events.some((e) => e.startsWith("revoke:")) ? "reg-2" : "reg-1";
    currentReg = nextReg;
    events.push(`authorize:${nextReg}`);
    return {
      registrationId: nextReg,
      descriptor: JSON.stringify({ registration_id: nextReg }),
    };
  });
  vi.mocked(f.adapter.install).mockImplementation(async (requestId) => {
    events.push(`install:${currentReg}`);
    present = true;
    remoteConnected = true;
    const receipt: NativeRequestReceipt = {
      requestId: requestId!,
      targetRegistrationId: currentReg,
      kind: "registration-claim",
      outcome: "succeeded",
    };
    f.receipts.set(requestId!, receipt);
    return receipt;
  });

  let onReset: (() => void) | undefined;
  let onSettled: ((state: HostMaintenanceState) => void) | undefined;
  const maintenance = {
    onHostReset: (listener: () => void) => {
      onReset = listener;
      return () => {};
    },
    onSettled: (listener: (state: HostMaintenanceState) => void) => {
      onSettled = listener;
      return () => {};
    },
    continuePending: async () => false,
    state: async (): Promise<HostMaintenanceState> => ({
      installation: "installed",
      updateAvailable: false,
    }),
    maintain: async (): Promise<HostMaintenanceState> => {
      present = false;
      remoteConnected = false;
      deviceId = "dev-after";
      onReset?.();
      const settled: HostMaintenanceState = {
        installation: "installed",
        updateAvailable: false,
        operation: {
          requestId: "dddddddd-dddd-4ddd-dddd-dddddddddddd",
          action: "reinstall",
          dataPolicy: "reset",
          phase: "completed",
          outcome: "succeeded",
        },
      };
      onSettled?.(settled);
      return settled;
    },
  } as unknown as LocalHostMaintenance;

  const session = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account", email: "account@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const account = new AccountComputeNodeService(
    {
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
    },
    session,
    undefined,
    maintenance
  );
  await account.configure({ desiredEnabled: true, workspaceId: "workspace" });
  expect(account.state().status).toBe("ready");

  await account.maintainHost({ action: "reinstall", dataPolicy: "reset" });
  await account.refresh();
  expect(account.state().status).toBe("ready");
  expect(account.state().bindingRegistrationId).toBe("reg-2");
  expect(events).toEqual([
    "authorize:reg-1",
    "install:reg-1",
    "revoke:reg-1",
    "authorize:reg-2",
    "install:reg-2",
  ]);
});

it("falls back to exact request lookup when registration correlation hits a fenced prior claim, and rebinds cleanly across two-step uninstall+reset -> reinstall", async () => {
  // 1. AgentVMMCommandAdapter.receipt falls back to `--request-id` alone when `--registration-id` hits a fenced prior claim.
  {
    const calls: string[][] = [];
    const run = vi.fn(async (_bin: string, args: string[]) => {
      calls.push(args);
      if (args.includes("--registration-id")) {
        throw new ComputeNodeCommandError(
          "the local owner removed this registration or Host installation",
          "command_failed",
          {
            code: "request_blocked",
            reason: "local_owner_fence",
            requestId: "11111111-1111-4111-8111-111111111111",
          }
        );
      }
      return "null";
    });
    const adapter = new AgentVMMCommandAdapter(
      "/mock/agent-vmm-lifecycle",
      run as never
    );
    const receipt = await adapter.receipt(
      "22222222-2222-4222-8222-222222222222",
      "reg-old"
    );
    expect(receipt).toBeUndefined();
    expect(calls).toHaveLength(2);
    expect(calls[0]).toContain("--registration-id");
    expect(calls[1]).not.toContain("--registration-id");
  }

  // 2. Two-step uninstall+reset -> reinstall+preserve revokes immediately on uninstall and rebinds back to ready on reinstall.
  const f = await fixture();
  let present = false;
  let hostInstalled = true;
  let currentReg = "reg-1";
  let deviceId = "dev-before";
  const events: string[] = [];
  vi.mocked(f.adapter.observe).mockImplementation(async () =>
    hostInstalled
      ? {
          host: "ready",
          connector: present ? "ready" : "absent",
          readability: "readable",
          salix: present ? "ready" : "unregistered",
          registration: present ? "present" : "absent",
          deviceId,
          deviceIdentityState: "ready",
        }
      : {
          host: "absent",
          connector: "absent",
          readability: "unreadable",
          salix: "unregistered",
          registration: "unreadable",
          reason: "helper_missing",
        }
  );
  vi.mocked(f.owner.inspect).mockImplementation(async ({ registrationId }) => ({
    status:
      registrationId === currentReg && present
        ? "ready"
        : events.includes(`revoke:${registrationId}`)
          ? "removed"
          : "ready",
    hostBound: true,
    deviceId: registrationId === "reg-1" ? "dev-before" : "dev-after",
    // Even if Gateway heartbeat has not timed out yet when uninstall/rebind runs:
    connected: !events.includes(`revoke:${registrationId}`),
    workActivity: "idle",
  }));
  vi.mocked(f.owner.revoke).mockImplementation(async ({ registrationId }) => {
    events.push(`revoke:${registrationId}`);
    return "removed";
  });
  const authRequestIds: string[] = [];
  vi.mocked(f.owner.authorize).mockImplementation(async ({ requestId }) => {
    authRequestIds.push(requestId);
    const nextReg = events.some((e) => e.startsWith("revoke:")) ? "reg-2" : "reg-1";
    currentReg = nextReg;
    events.push(`authorize:${nextReg}`);
    return {
      registrationId: nextReg,
      descriptor: JSON.stringify({ registration_id: nextReg }),
    };
  });
  vi.mocked(f.adapter.install).mockImplementation(async (requestId) => {
    events.push(`install:${currentReg}`);
    present = true;
    const receipt: NativeRequestReceipt = {
      requestId: requestId!,
      targetRegistrationId: currentReg,
      kind: "registration-claim",
      outcome: "succeeded",
    };
    f.receipts.set(requestId!, receipt);
    return receipt;
  });

  let onReset: (() => void) | undefined;
  let onSettled: ((state: HostMaintenanceState) => void) | undefined;
  const maintenance = {
    onHostReset: (listener: () => void) => {
      onReset = listener;
      return () => {};
    },
    onSettled: (listener: (state: HostMaintenanceState) => void) => {
      onSettled = listener;
      return () => {};
    },
    continuePending: async () => false,
    state: async (): Promise<HostMaintenanceState> => ({
      installation: hostInstalled ? "installed" : "not_installed",
      updateAvailable: false,
    }),
    maintain: async (input: {
      action: "uninstall" | "reinstall" | "update";
      dataPolicy: "reset" | "preserve";
    }): Promise<HostMaintenanceState> => {
      if (input.action === "uninstall") {
        present = false;
        hostInstalled = false;
        deviceId = "dev-after";
        if (input.dataPolicy === "reset") onReset?.();
        const settled: HostMaintenanceState = {
          installation: "not_installed",
          updateAvailable: false,
          operation: {
            requestId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            action: "uninstall",
            dataPolicy: input.dataPolicy,
            phase: "completed",
            outcome: "succeeded",
          },
        };
        onSettled?.(settled);
        return settled;
      }
      hostInstalled = true;
      const settled: HostMaintenanceState = {
        installation: "installed",
        updateAvailable: false,
        operation: {
          requestId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
          action: input.action,
          dataPolicy: input.dataPolicy,
          phase: "completed",
          outcome: "succeeded",
        },
      };
      onSettled?.(settled);
      return settled;
    },
  } as unknown as LocalHostMaintenance;

  const session = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account", email: "account@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const account = new AccountComputeNodeService(
    {
      filePath: f.filePath,
      adapter: f.adapter,
      installAuthorization: f.owner,
      hostInstallation: async () => (hostInstalled ? "installed" : "not_installed"),
      platform: "darwin",
      arch: "arm64",
      clock: f.clock,
    },
    session,
    undefined,
    maintenance
  );
  await account.configure({ desiredEnabled: true, workspaceId: "workspace" });
  expect(account.state().status).toBe("ready");

  await account.maintainHost({ action: "uninstall", dataPolicy: "reset" });
  await account.refresh();
  expect(events).toEqual(["authorize:reg-1", "install:reg-1", "revoke:reg-1"]);
  expect(account.state().status).toBe("action_required");
  expect(account.state().problem).toBe("host_uninstalled");

  await account.maintainHost({ action: "reinstall", dataPolicy: "preserve" });
  await account.refresh();
  expect(account.state().status).toBe("ready");
  expect(account.state().problem).toBeUndefined();
  expect(account.state().bindingRegistrationId).toBe("reg-2");
  expect(authRequestIds).toHaveLength(2);
  expect(authRequestIds[1]).not.toBe(authRequestIds[0]);
  expect(events).toEqual([
    "authorize:reg-1",
    "install:reg-1",
    "revoke:reg-1",
    "authorize:reg-2",
    "install:reg-2",
  ]);

  // 3. Disabling between uninstall+reset and reinstall+preserve keeps the node stopped.
  await account.maintainHost({ action: "uninstall", dataPolicy: "reset" });
  await account.refresh();
  await account.configure({ desiredEnabled: false });
  await account.maintainHost({ action: "reinstall", dataPolicy: "preserve" });
  await account.refresh();
  expect(account.state().desiredEnabled).toBe(false);
  expect(authRequestIds).toHaveLength(2);
});
