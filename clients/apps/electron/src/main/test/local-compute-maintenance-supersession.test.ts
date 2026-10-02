import { chmod, mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { LocalComputeOperator } from "../modules/compute-node/local-operator";

const oldRequest = "d559fe82-f45a-4f6a-b727-748d1328416c";
const newRequest = "642785ac-1410-41bc-a9bd-2e115bc55765";
const resetRequest = "0e85b8cf-4bbe-4fb4-b4cd-c5845e01077e";
const secondReset = "d2762525-e187-45d3-9bcb-28eecbfb27e5";
const date = "2026-10-02T12:00:00Z";

async function saveRequest(directory: string, requestId: string, operationId?: string) {
  await writeFile(
    join(directory, `${requestId}.json`),
    JSON.stringify({
      request: {
        requestId,
        plan: {
          targetKind: "LOCAL_DISPOSAL_TARGET_KIND_REGISTRATION",
          targetId: `target-${requestId}`,
          revision: "1",
          environmentCount: "1",
        },
        irreversibleConfirmation: true,
      },
      ...(operationId ? { operationId } : {}),
    })
  );
  await writeFile(join(directory, "current.json"), JSON.stringify({ requestId }));
}
function makeRunner() {
  return vi.fn(async (_path: string, args: string[], input?: string) => {
    if (args[0] === "local-environments")
      return JSON.stringify({ collectedAt: date, environments: [] });
    if (args[0] === "local-disk") return JSON.stringify({ collectedAt: date });
    if (args[0] === "local-operation")
      return JSON.stringify({
        operation: {
          id: JSON.parse(input!).operationId,
          state: "OPERATION_STATE_RUNNING",
        },
      });
    throw new Error("An old destructive request must not run after reset");
  });
}
function operator(
  directory: string,
  run: ConstructorParameters<typeof LocalComputeOperator>[0]["run"] = makeRunner()
) {
  return new LocalComputeOperator({
    journalDirectory: directory,
    lifecyclePath: "isolated-helper",
    run,
  });
}

describe("full Host reset supersedes only the captured local disposal", () => {
  it("freezes the exact pointer, preserves a later task, and never resumes the old target", async () => {
    const directory = await mkdtemp(join(tmpdir(), "local-reset-marker-"));
    const run = makeRunner();
    const local = operator(directory, run);
    expect(await local.currentDisposalRequest()).toBeUndefined();
    await saveRequest(directory, oldRequest, "old-operation");
    const captured = await local.currentDisposalRequest();
    await saveRequest(directory, newRequest, "new-operation");
    await local.supersedeAfterHostReset(captured!, resetRequest);
    expect(await local.currentDisposalRequest()).toBe(newRequest);
    expect(await local.resume(oldRequest)).toEqual({
      outcome: "superseded",
      requestId: oldRequest,
      resetRequestId: resetRequest,
    });
    expect(run).not.toHaveBeenCalled();
    expect((await local.overview({})).disposal).toMatchObject({
      requestId: newRequest,
      outcome: "pending",
      operationId: "new-operation",
    });
    expect(await local.resume(newRequest)).toMatchObject({
      requestId: newRequest,
      outcome: "pending",
    });
    expect(
      JSON.parse(await readFile(join(directory, `${oldRequest}.json`), "utf8"))
    ).toMatchObject({ operationId: "old-operation" });
  });

  it("keeps an immutable reset marker across restart without claiming native completion", async () => {
    const directory = await mkdtemp(join(tmpdir(), "local-reset-marker-"));
    await saveRequest(directory, oldRequest);
    await operator(directory).supersedeAfterHostReset(oldRequest, resetRequest);
    const run = makeRunner();
    const reopened = operator(directory, run);
    await reopened.supersedeAfterHostReset(oldRequest, secondReset);
    expect(await reopened.resume(oldRequest)).toEqual({
      outcome: "superseded",
      requestId: oldRequest,
      resetRequestId: resetRequest,
    });
    expect(run).not.toHaveBeenCalled();
    expect((await reopened.overview({})).disposal).toEqual({
      outcome: "superseded",
      requestId: oldRequest,
      resetRequestId: resetRequest,
    });
    expect(
      run.mock.calls.every(
        ([, args]) => args[0] !== "local-operation" && args[0] !== "local-execute"
      )
    ).toBe(true);
    expect(JSON.parse(await readFile(join(directory, "current.json"), "utf8"))).toEqual(
      { requestId: oldRequest }
    );
  });

  it("a late original execution response cannot replace the independent reset marker", async () => {
    const directory = await mkdtemp(join(tmpdir(), "local-reset-marker-"));
    await saveRequest(directory, oldRequest);
    let finish!: (value: string) => void;
    let started!: () => void;
    const commandStarted = new Promise<void>((resolve) => {
      started = resolve;
    });
    const delayed = new Promise<string>((resolve) => {
      finish = resolve;
    });
    const run = vi.fn(async (_path: string, args: string[]) => {
      if (args[0] !== "local-execute") throw new Error("unexpected helper effect");
      started();
      return delayed;
    });
    const local = operator(directory, run);
    const pending = local.resume(oldRequest);
    await commandStarted;
    await local.supersedeAfterHostReset(oldRequest, resetRequest);
    finish(
      JSON.stringify({
        operation: { id: "old-late-operation", state: "OPERATION_STATE_RUNNING" },
      })
    );
    expect(await pending).toEqual({
      outcome: "superseded",
      requestId: oldRequest,
      resetRequestId: resetRequest,
    });
    expect(await operator(directory).resume(oldRequest)).toEqual({
      outcome: "superseded",
      requestId: oldRequest,
      resetRequestId: resetRequest,
    });
    expect(
      JSON.parse(await readFile(join(directory, `${oldRequest}.json`), "utf8"))
    ).toMatchObject({ operationId: "old-late-operation" });
  });

  it("an absent reset marker preserves ordinary local receipt observation", async () => {
    const directory = await mkdtemp(join(tmpdir(), "local-reset-marker-"));
    await saveRequest(directory, oldRequest, "retained-operation");
    const local = operator(directory);
    expect(await local.currentDisposalRequest()).toBe(oldRequest);
    expect(await local.resume(oldRequest)).toMatchObject({
      outcome: "pending",
      operationId: "retained-operation",
    });
    await expect(
      readFile(join(directory, "superseded", `${oldRequest}.json`))
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not execute a target when its reset marker is unreadable", async () => {
    const directory = await mkdtemp(join(tmpdir(), "local-reset-marker-"));
    await saveRequest(directory, oldRequest);
    await mkdir(join(directory, "superseded"));
    await writeFile(join(directory, "superseded", `${oldRequest}.json`), "broken");
    const run = makeRunner();
    await expect(operator(directory, run).resume(oldRequest)).rejects.toThrow();
    expect(run).not.toHaveBeenCalled();
  });
  it.skipIf(!process.getuid || process.getuid() === 0)(
    "retries marker persistence after an I/O failure without reopening the old target",
    async () => {
      const directory = await mkdtemp(join(tmpdir(), "local-reset-marker-"));
      await saveRequest(directory, oldRequest);
      const markerDirectory = join(directory, "superseded");
      await mkdir(markerDirectory, { mode: 0o500 });
      const run = makeRunner();
      const local = operator(directory, run);
      try {
        await expect(
          local.supersedeAfterHostReset(oldRequest, resetRequest)
        ).rejects.toThrow();
        expect(await local.resume(oldRequest)).toMatchObject({ outcome: "superseded" });
        expect(run).not.toHaveBeenCalled();
      } finally {
        await chmod(markerDirectory, 0o700);
      }
      await local.supersedeAfterHostReset(oldRequest, resetRequest);
      expect(await operator(directory, run).resume(oldRequest)).toEqual({
        outcome: "superseded",
        requestId: oldRequest,
        resetRequestId: resetRequest,
      });
    }
  );
});
