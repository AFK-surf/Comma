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

  test("a network failure stays unresolved across eviction", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    await expect(control.run(permit, "import", async () => { throw new Error("response lost"); }, () => ({}))).rejects.toThrow("response lost");
    const replacement = new ContainerControl(disk);
    await replacement.seal(sealed);
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
  test("an approved sealed discard supersedes import without late completion changing destruction", async () => {
    const disk = storage();
    const control = new ContainerControl(disk);
    await control.open(permit);
    const response = deferred<string>();
    const started = deferred<void>();
    const importing = control.run(permit, "import", () => {
      started.resolve(); return response.promise;
    }, () => ({ status: 200 }), { archive_operation: "snapshot-1" });
    const abandoned = expect(importing).rejects.toThrow("control_command_changed");
    await started.promise;
    await control.seal(sealed);
    const replacement = new ContainerControl(disk);
    const destroy = vi.fn(async () => "stopped");
    expect(await replacement.run({ ...sealed, claim_id: "discard" }, "destroy", destroy, () => ({ status: 200 }),
      { sealed: true, discard: true })).toBe("stopped");
    response.resolve("imported");
    await abandoned;
    expect(replacement.observe()).toMatchObject({ sealed: true, pending: null,
      last_terminal: { action: "destroy", claim_id: "discard", outcome: "completed" } });
    await expect(control.run(permit, "ensure", destroy, () => ({}))).rejects.toThrow("stale_control_permit");
    expect(destroy).toHaveBeenCalledTimes(1);
  });

  test("discard cannot supersede an unresolved destruction or run against an open carrier", async () => {
    const control = new ContainerControl(storage());
    await control.open(permit);
    const destroy = vi.fn(async () => undefined);
    await expect(control.run(permit, "destroy", destroy, () => ({}), { discard: true })).rejects.toThrow("control_seal_required");
    await control.seal(sealed);
    await expect(control.run(sealed, "destroy", async () => { throw new Error("response lost"); }, () => ({}),
      { sealed: true, discard: true })).rejects.toThrow("response lost");
    await expect(control.run(command("another", sealed), "destroy", destroy, () => ({}),
      { sealed: true, discard: true })).rejects.toThrow("control_command_unsettled");
    expect(destroy).not.toHaveBeenCalled();
  });

});
