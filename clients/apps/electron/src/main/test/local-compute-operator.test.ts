import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
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
        return JSON.stringify({
          operation: { id: "original-host-receipt", state: "OPERATION_STATE_RUNNING" },
        });
      case "local-operation":
        return JSON.stringify({
          operation: {
            id: "original-host-receipt",
            state: "OPERATION_STATE_SUCCEEDED",
          },
        });
      default:
        throw new Error("unexpected helper command");
    }
  });
}

describe("trusted local operator management", () => {
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
    let decision!: (value: boolean) => void;
    const confirm = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          decision = resolve;
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
    await vi.waitFor(() => expect(confirm).toHaveBeenCalledTimes(1));
    decision(false);
    expect(await pending).toEqual({ outcome: "cancelled" });
    expect(run.mock.calls.some(([, args]) => args[0] === "local-execute")).toBe(false);
    const next = local.dispose({ key: page.environments[0]!.key });
    await vi.waitFor(() => expect(confirm).toHaveBeenCalledTimes(2));
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
