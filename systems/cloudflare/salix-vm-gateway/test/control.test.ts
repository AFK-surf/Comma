import { describe, expect, test, vi } from "vitest";
import { ContainerControl, type ControlPermit, type ControlState, type ControlStorage } from "../src/control";

const permit: ControlPermit = { owner_id: "workload-1", operation_id: "wake-1", generation: 1, revision: 10, claim_id: "claim-1" };
const command = (claim: string, fields: Partial<ControlPermit> = {}) => ({ ...permit, claim_id: claim, ...fields });
const sealed = command("seal", { operation_id: "archive-1", revision: 11 });

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

function storage(): ControlStorage {
  let value: ControlState | undefined;
  return { read: () => value && structuredClone(value), write: (next) => { value = structuredClone(next); }, sync: async () => {} };
}

describe("persistent Container carrier control", () => {
  test("seal persists during an import and only its exact response settles the admitted command", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    const response = deferred<string>();
    const started = deferred<void>();
    const importCall = control.run(permit, "import", () => { started.resolve(); return response.promise; }, () => ({ status: 200 }), { archive_operation: "snapshot-1" });
    await started.promise;
    expect((await control.seal(sealed)).pending).toMatchObject({ claim_id: "claim-1", archive_operation: "snapshot-1" });
    const replacement = new ContainerControl(disk);
    const destroy = vi.fn(async () => undefined);
    await expect(replacement.run(command("destroy", sealed), "destroy", destroy, () => ({}), { sealed: true })).rejects.toThrow("control_command_unsettled");
    await expect(replacement.open(command("open", { revision: 12 }))).rejects.toThrow("control_command_unsettled");
    expect(destroy).not.toHaveBeenCalled();
    response.resolve("imported");
    expect(await importCall).toBe("imported");
    expect(replacement.observe()).toMatchObject({ sealed: true, pending: null, last_terminal: { claim_id: "claim-1", outcome: "completed" } });
    await expect(replacement.run(permit, "ensure", destroy, () => ({}))).rejects.toThrow("stale_control_permit");
  });

  test("a network failure stays unresolved across eviction and no ready observation settles import", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    await expect(control.run(permit, "import", async () => { throw new Error("response lost"); }, () => ({}))).rejects.toThrow("response lost");
    const replacement = new ContainerControl(disk);
    await replacement.seal(sealed);
    await replacement.confirmReady(sealed);
    expect(replacement.observe()?.pending).toMatchObject({ action: "import", claim_id: "claim-1" });
    const destroy = vi.fn(async () => undefined);
    await expect(replacement.run(sealed, "destroy", destroy, () => ({}), { sealed: true })).rejects.toThrow("control_command_unsettled");
    expect(destroy).not.toHaveBeenCalled();
  });

  test("seal wins a delayed admission flush without allowing its late native call", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    const flush = deferred<void>();
    disk.sync = vi.fn().mockImplementationOnce(() => flush.promise).mockResolvedValue(undefined);
    const start = vi.fn(async () => "started");
    const call = control.run(permit, "ensure", start, () => ({}));
    const rejected = expect(call).rejects.toThrow("stale_control_permit");
    await control.seal(sealed);
    flush.resolve();
    await rejected;
    expect(start).not.toHaveBeenCalled();
    expect(control.observe()).toMatchObject({ sealed: true, pending: null, last_terminal: { outcome: "not_issued", claim_id: "claim-1" } });
  });

  test("only an issued native start can be confirmed ready; an unissued intent cannot", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    const beforeStart = deferred<void>();
    const started = deferred<void>();
    const call = control.run(permit, "ensure", async () => {
      started.resolve();
      await beforeStart.promise;
      control.startIssued(permit);
      throw new Error("ready response lost");
    }, () => ({}));
    const rejected = expect(call).rejects.toThrow("ready response lost");
    await started.promise;
    await control.confirmReady(permit);
    expect(control.observe()?.pending).not.toBeNull();
    beforeStart.resolve();
    await rejected;
    const replacement = new ContainerControl(disk);
    await replacement.confirmReady(permit);
    expect(replacement.observe()).toMatchObject({ pending: null, last_terminal: { action: "ensure", start_issued: true, outcome: "completed" } });
  });

  test("destroy retries cannot cross an explicitly reopened owner generation", async () => {
    const control = new ContainerControl(storage());
    await control.open(permit);
    await control.seal(sealed);
    const destroy = vi.fn(async () => undefined);
    await control.run(sealed, "destroy", destroy, () => ({}), { sealed: true });
    await expect(control.run(sealed, "destroy", destroy, () => ({}), { sealed: true })).rejects.toThrow("control_command_completed");
    const next = command("next", { operation_id: "wake-2", generation: 2, revision: 12 });
    await control.open(next);
    await expect(control.run(sealed, "destroy", destroy, () => ({}), { sealed: true })).rejects.toThrow("stale_control_owner");
    await expect(control.open({ ...next, owner_id: "another-workload" })).rejects.toThrow("stale_control_owner");
    expect(destroy).toHaveBeenCalledTimes(1);
  });

  test("a durable-storage failure prevents native dispatch and never erases pending evidence", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    disk.sync = async () => { throw new Error("storage unavailable"); };
    const start = vi.fn(async () => undefined);
    await expect(control.run(permit, "ensure", start, () => ({}))).rejects.toThrow("storage unavailable");
    expect(start).not.toHaveBeenCalled();
    expect(control.observe()?.pending?.claim_id).toBe(permit.claim_id);
  });
});
