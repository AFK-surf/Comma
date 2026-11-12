import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { localComputeOverviewSchema } from "@comma/native-bridge";
import { LocalComputeOperator } from "../modules/compute-node/local-operator";
import { ComputeNodeCommandError } from "../modules/compute-node";

const disk = {
  collectedAt: "2026-10-01T10:00:00Z",
  bootId: "boot",
  guestStateFs: { usedBytes: "55", capacityBytes: "100", importReservationBytes: "5" },
};
const row = {
  id: "private-environment",
  origin: "remote",
  state: "unknown",
  registrationId: "original-registration",
  allocationId: "allocation",
  allocationGeneration: "4",
  revision: "7",
  displayName: "old-account-secret",
};
function runner() {
  let requestId = "";
  return vi.fn(async (_file: string, args: string[], input?: string) => {
    const body = JSON.parse(input ?? "{}") as Record<string, unknown>;
    switch (args[0]) {
      case "local-disk":
        return JSON.stringify(disk);
      case "local-environments":
        return JSON.stringify({
          collectedAt: disk.collectedAt,
          bootId: "boot",
          environments: [row],
          nextCursor: "cursor",
        });
      case "local-plan":
        return JSON.stringify({
          plan: {
            targetKind: body.targetKind,
            targetId: body.targetId,
            revision: "17",
            environmentCount: "101",
            displayName: "old-cloud-secret",
          },
        });
      case "local-execute":
        requestId = String(body.requestId);
        return JSON.stringify({
          operation: {
            id: "original-host-receipt",
            requestId,
            kind: "local-disposal",
            resource: { kind: "environment", environmentId: "original-registration" },
            state: "OPERATION_STATE_RUNNING",
          },
        });
      case "local-operation":
        return JSON.stringify({
          operation: {
            id: "original-host-receipt",
            requestId,
            kind: "local-disposal",
            resource: { kind: "environment", environmentId: "original-registration" },
            state: "OPERATION_STATE_SUCCEEDED",
          },
        });
      default:
        throw new Error("unexpected helper command");
    }
  });
}

describe("trusted local operator management", () => {
  it.each(["current", "old", "malformed", "nondecimal"])(
    "passes fixed owner totals through the bridge on a paginated environment page (%s)",
    async (producer) => {
      const run = runner(),
        fallback = run.getMockImplementation()!;
      const breakdown = {
        imageRuntimeBytes: "30",
        buildCacheBytes: "10",
        privateBytes: "12",
        otherBytes: "3",
        breakdownSampledAt: disk.collectedAt,
      };
      run.mockImplementation(async (file, args, input) => {
        if (args[0] === "local-disk")
          return JSON.stringify({
            ...disk,
            guestStateFs: {
              ...disk.guestStateFs,
              ...(producer === "old"
                ? {}
                : {
                    ...breakdown,
                    ...(producer === "malformed"
                      ? { privateBytes: "18446744073709551616" }
                      : producer === "nondecimal"
                        ? { privateBytes: "invalid" }
                        : {}),
                  }),
            },
          });
        return fallback(file, args, input);
      });
      const local = new LocalComputeOperator({
        lifecyclePath: "helper",
        journalDirectory: await mkdtemp(join(tmpdir(), "local-disk-")),
        run,
      });
      const page = localComputeOverviewSchema.parse(
        await local.overview({ cursor: "prior" })
      );
      expect(page.availability).toBe("available");
      expect(page.nextCursor).toBe("cursor");
      expect(page.environments).toHaveLength(1);
      expect(page.environments[0]?.canDisposeLocal).toBe(true);
      expect(page.disk).toEqual({
        ...disk.guestStateFs,
        ...(producer === "current" ? breakdown : {}),
      });
      expect(run.mock.calls.map((call) => call[1][0])).toEqual([
        "local-environments",
        "local-disk",
      ]);
      expect(JSON.parse(run.mock.calls[0]![2]!)).toEqual({ afterId: "prior" });
    }
  );
  it("projects one whole-registration scope and adopts only the native owner's explicit original receipt after a duplicate request loses its reply", async () => {
    const run = runner();
    const fallback = run.getMockImplementation()!;
    const directory = await mkdtemp(join(tmpdir(), "local-exact-owner-"));
    let originalRequest = "",
      loseReply = false;
    const operation = () => ({
      id: "owner-original",
      requestId: originalRequest,
      kind: "local-disposal",
      resource: { kind: "environment", environmentId: row.registrationId },
      state: "OPERATION_STATE_SUCCEEDED",
    });
    run.mockImplementation(async (file, args, input) => {
      if (args[0] === "local-environments")
        return JSON.stringify({
          collectedAt: disk.collectedAt,
          bootId: "boot",
          environments: [
            row,
            { ...row, id: "second-environment", allocationId: "second-allocation" },
          ],
        });
      if (args[0] === "local-execute") {
        originalRequest ||= JSON.parse(input!).requestId;
        if (loseReply) {
          loseReply = false;
          throw new ComputeNodeCommandError("reply lost", "outcome_unknown");
        }
        return JSON.stringify({ operation: operation() });
      }
      if (args[0] === "local-operation")
        return JSON.stringify({ operation: operation() });
      return fallback(file, args, input);
    });
    const local = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: directory,
      run,
      confirm: async () => true,
    });
    const page = await local.overview({});
    expect(page.environments.map((environment) => environment.disposalScope)).toEqual([
      { key: page.environments[0]!.key, label: "stration" },
      { key: page.environments[0]!.key, label: "stration" },
    ]);
    expect(page.environments.map((environment) => environment.canDisposeLocal)).toEqual(
      [true, false]
    );
    const first = await local.dispose({ key: page.environments[0]!.key });
    loseReply = true;
    const repeated = await local.dispose({ key: page.environments[1]!.key });
    expect(repeated).toMatchObject({ outcome: "unknown" });
    expect(repeated.requestId).not.toBe(first.requestId);
    expect((await local.overview({})).disposal).toMatchObject({
      requestId: repeated.requestId,
      outcome: "unknown",
    });
    const reopened = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: directory,
      run,
    });
    expect(await reopened.resume(repeated.requestId!)).toMatchObject({
      outcome: "completed",
      operationId: "owner-original",
    });
    const saved = JSON.parse(
      await readFile(join(directory, `${repeated.requestId}.json`), "utf8")
    );
    expect(saved).toMatchObject({
      request: { requestId: repeated.requestId },
      operationId: "owner-original",
      operationRequestId: first.requestId,
    });
    expect((await reopened.overview({})).disposal).toMatchObject({
      outcome: "completed",
      operationId: "owner-original",
    });
    originalRequest = "unrelated-request";
    await expect(reopened.resume(repeated.requestId!)).rejects.toThrow(
      "request identity changed"
    );
  });

  it("rejects a native disposal response from a different resource instead of attaching its success", async () => {
    const run = runner();
    const fallback = run.getMockImplementation()!;
    run.mockImplementation(async (file, args, input) =>
      args[0] === "local-execute"
        ? JSON.stringify({
            operation: {
              id: "other-operation",
              requestId: "other-request",
              kind: "local-disposal",
              resource: { kind: "environment", environmentId: "another-registration" },
              state: "OPERATION_STATE_SUCCEEDED",
            },
          })
        : fallback(file, args, input)
    );
    const local = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: await mkdtemp(join(tmpdir(), "local-wrong-owner-")),
      run,
      confirm: async () => true,
    });
    const page = await local.overview({});
    await expect(local.dispose({ key: page.environments[0]!.key })).rejects.toThrow(
      "another target"
    );
    expect((await local.overview({})).disposal?.outcome).toBe("unknown");
  });

  it("reads one page and summary, then deletes the entire registration only after native confirmation", async () => {
    const run = runner();
    const confirm = vi.fn(async () => true);
    const directory = await mkdtemp(join(tmpdir(), "local-disposal-"));
    const local = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: directory,
      run,
      confirm,
    });
    const page = await local.overview({});
    expect(run.mock.calls.map(([, args]) => args[0])).toEqual([
      "local-environments",
      "local-disk",
    ]);
    expect(JSON.stringify(page)).not.toContain("secret");
    expect(page.environments[0]).toMatchObject({
      canReadWorkloads: false,
      canOperate: false,
    });
    const result = await local.dispose({ key: page.environments[0]!.key });
    expect(confirm).toHaveBeenCalledWith({
      kind: "registration",
      label: "stration",
      environmentCount: "101",
    });
    const executed = JSON.parse(
      run.mock.calls.find(([, args]) => args[0] === "local-execute")![2]!
    );
    expect(executed).toMatchObject({
      irreversibleConfirmation: true,
      plan: { targetId: "original-registration", revision: "17" },
    });
    expect(
      JSON.parse(await readFile(join(directory, `${result.requestId}.json`), "utf8"))
    ).toMatchObject({ operationId: "original-host-receipt", request: executed });
    const reopened = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: directory,
      run,
    });
    expect(await reopened.resume(result.requestId!)).toMatchObject({
      outcome: "completed",
      operationId: "original-host-receipt",
    });
  });

  it("cancels without effects and rejects a target changed while native confirmation is open", async () => {
    const run = runner();
    let shown = Promise.withResolvers<void>();
    let decision!: (value: boolean) => void;
    const confirm = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          decision = resolve;
          shown.resolve();
        })
    );
    const local = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: await mkdtemp(join(tmpdir(), "local-cancel-")),
      run,
      confirm,
    });
    const page = await local.overview({});
    const pending = local.dispose({ key: page.environments[0]!.key });
    await shown.promise;
    expect(confirm).toHaveBeenCalledTimes(1);
    decision(false);
    expect(await pending).toEqual({ outcome: "cancelled" });
    expect(run.mock.calls.some(([, args]) => args[0] === "local-execute")).toBe(false);
    shown = Promise.withResolvers<void>();
    const next = local.dispose({ key: page.environments[0]!.key });
    await shown.promise;
    expect(confirm).toHaveBeenCalledTimes(2);
    run.mockImplementationOnce(async () =>
      JSON.stringify({
        collectedAt: disk.collectedAt,
        bootId: "another-boot",
        environments: [row],
      })
    );
    await local.overview({});
    decision(true);
    await expect(next).rejects.toThrow("environment changed");
    expect(run.mock.calls.some(([, args]) => args[0] === "local-execute")).toBe(false);
  });

  it("persists an unknown acceptance and resumes only the same confirmed request after reopening", async () => {
    const run = runner();
    const directory = await mkdtemp(join(tmpdir(), "local-unknown-"));
    const local = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: directory,
      run,
      confirm: async () => true,
    });
    const page = await local.overview({});
    const initial = run.getMockImplementation()!;
    run.mockImplementation(async (file, args, input) => {
      if (args[0] === "local-execute")
        throw new ComputeNodeCommandError("timed out", "outcome_unknown");
      return initial(file, args, input);
    });
    const result = await local.dispose({ key: page.environments[0]!.key });
    expect(result.outcome).toBe("unknown");
    const original = run.mock.calls.find(([, args]) => args[0] === "local-execute")![2];
    run.mockImplementation(initial);
    const reopened = new LocalComputeOperator({
      lifecyclePath: "helper",
      journalDirectory: directory,
      run,
    });
    expect(await reopened.resume(result.requestId!)).toMatchObject({
      outcome: "pending",
      operationId: "original-host-receipt",
    });
    expect(run.mock.calls.at(-1)![2]).toBe(original);
  });
});
