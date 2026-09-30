import { Buffer } from "node:buffer";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sameSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LocalDataDirtyReplayQueue } from "../modules/local-data";
import {
  LocalDataUtilityRepository,
  type LocalDataWorkerConnection,
  type LocalDataWorkerHost,
} from "../modules/local-data/repository";
import {
  LocalDataRpcClosedError,
  createAsyncCallMessagePortChannel,
  type AsyncCallMessagePort,
} from "../../shared/async-call-message-port";
import {
  LOCAL_DATA_SCHEMA_VERSION,
  LOCAL_DATA_WORKER_CONNECT_MESSAGE,
  LOCAL_DATA_WORKER_PROTOCOL_VERSION,
  LocalDataWriteFailure,
  assertLocalDataWriteAck,
  assertLocalDataWriteRequest,
  type LocalDataOpenInput,
  type LocalDataWriteRequest,
  type ProductInboxCacheApplyInput,
} from "../../shared/local-data";
import {
  LocalDataWorkerService,
  isLocalDataWorkerConnectMessage,
  startLocalDataUtilityWorker,
  type LocalDataUtilityParentPort,
} from "../../utility/local-data-worker";

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true });
  }
});

describe("LocalDataWorkerService", () => {
  it("owns one database and returns operation/worker-generation acknowledgements", () => {
    const worker = new LocalDataWorkerService();
    const databasePath = tempDatabasePath();

    expect(worker.open({ databasePath, workerGeneration: 3 })).toEqual({
      schemaVersion: LOCAL_DATA_SCHEMA_VERSION,
      workerGeneration: 3,
    });
    expect(() => worker.open({ databasePath, workerGeneration: 4 })).toThrow(
      "already open"
    );

    const input = productInboxWrite("replace");
    expect(
      worker.applyProductInboxSync({
        input,
        operationId: "persist-1",
        workerGeneration: 3,
      })
    ).toEqual({
      operationId: "persist-1",
      session: input.session,
      workerGeneration: 3,
    });
    expect(
      worker.listProductInboxItems({
        audience: "https://api.comma.test",
        principalId: "principal-a",
      })
    ).toEqual([expect.objectContaining({ conversationId: "cnv_1" })]);
    expect(() =>
      worker.applyProductInboxSync({
        input,
        operationId: "late",
        workerGeneration: 2,
      })
    ).toThrow("stale workerGeneration");

    worker.close();
    expect(() => worker.schemaVersion()).toThrow("not open");
  });

  it("validates the utility handshake and rejects non-JSON persistence values", () => {
    expect(
      isLocalDataWorkerConnectMessage({
        protocolVersion: LOCAL_DATA_WORKER_PROTOCOL_VERSION,
        type: LOCAL_DATA_WORKER_CONNECT_MESSAGE,
      })
    ).toBe(true);
    expect(
      isLocalDataWorkerConnectMessage({
        protocolVersion: LOCAL_DATA_WORKER_PROTOCOL_VERSION + 1,
        type: LOCAL_DATA_WORKER_CONNECT_MESSAGE,
      })
    ).toBe(false);

    const request = {
      input: productInboxWrite("merge"),
      operationId: "persist-json",
      workerGeneration: 1,
    };
    request.input.workspaces.items[0]!.raw = {
      invalid: undefined,
    } as never;
    expect(() => assertLocalDataWriteRequest(request)).toThrow("JSON-compatible");

    const nonNormalizedAudience = productInboxWrite("merge");
    nonNormalizedAudience.audience = " https://api.comma.test ";
    expect(() =>
      assertLocalDataWriteRequest({
        input: nonNormalizedAudience,
        operationId: "persist-audience",
        workerGeneration: 1,
      })
    ).toThrow("already be normalized");

    const mismatchedAudience = productInboxWrite("merge");
    mismatchedAudience.workspaces.items[0]!.audience = "https://other-api.comma.test";
    expect(() =>
      assertLocalDataWriteRequest({
        input: mismatchedAudience,
        operationId: "persist-mismatch",
        workerGeneration: 1,
      })
    ).toThrow("match the request principalId and audience");

    const mismatchedWorkspace = productInboxWrite("merge");
    mismatchedWorkspace.conversations!.items[0]!.workspaceId = "wsp_other";
    expect(() =>
      assertLocalDataWriteRequest({
        input: mismatchedWorkspace,
        operationId: "persist-workspace-mismatch",
        workerGeneration: 1,
      })
    ).toThrow("match the request workspace partition");

    expect(() =>
      assertLocalDataWriteRequest({
        input: productInboxWrite("merge"),
        operationId: "persist-reflected",
        reflectedToken: "must-not-cross",
        workerGeneration: 1,
      } as never)
    ).toThrow("unexpected field reflectedToken");
    const reflectedSession = productInboxWrite("merge").session;
    expect(() =>
      assertLocalDataWriteAck({
        operationId: "persist-json",
        reflectedToken: "must-not-cross",
        session: reflectedSession,
        workerGeneration: 1,
      } as never)
    ).toThrow("unexpected field reflectedToken");
  });
});

describe("local-data utility bootstrap", () => {
  it("accepts one typed transferred port and exits when the parent channel closes", () => {
    const parentPort = new FakeUtilityParentPort();
    const port = new FakeMessagePort();
    const scheduled: Array<() => void> = [];
    const exit = vi.fn();

    startLocalDataUtilityWorker({
      exit,
      parentPort,
      scheduleExit: (callback) => {
        scheduled.push(callback);
      },
    });
    parentPort.emit({
      data: {
        protocolVersion: LOCAL_DATA_WORKER_PROTOCOL_VERSION,
        type: LOCAL_DATA_WORKER_CONNECT_MESSAGE,
      },
      ports: [port],
    });

    port.emitClose();
    expect(scheduled).toHaveLength(1);
    scheduled[0]?.();
    expect(exit).toHaveBeenCalledWith(0);
  });

  it("rejects a handshake without exactly one transferred port", () => {
    const parentPort = new FakeUtilityParentPort();
    startLocalDataUtilityWorker({ parentPort });

    expect(() =>
      parentPort.emit({
        data: {
          protocolVersion: LOCAL_DATA_WORKER_PROTOCOL_VERSION,
          type: LOCAL_DATA_WORKER_CONNECT_MESSAGE,
        },
        ports: [],
      })
    ).toThrow("invalid connect handshake");
  });
});

describe("LocalDataDirtyReplayQueue", () => {
  it("replays the exact dirty operation after restart and ignores late acknowledgements", () => {
    const queue = new LocalDataDirtyReplayQueue(() => true);
    const input = productInboxWrite("merge");
    queue.enqueue("persist-1", input);

    input.audience = "https://mutated.comma.test";
    input.workspaces.mode = "replace";
    queue.startWorker(1);
    const [first] = queue.takePending().requests;
    expect(first).toMatchObject({
      input: {
        audience: "https://api.comma.test",
        conversations: { mode: "merge" },
        workspaces: { mode: "merge" },
      },
      operationId: "persist-1",
      workerGeneration: 1,
    });

    queue.startWorker(2);
    expect(
      queue.acceptAck({
        operationId: "persist-1",
        session: first!.input.session,
        workerGeneration: 1,
      })
    ).toEqual({ status: "ignored" });
    expect(queue.size).toBe(1);

    const [replayed] = queue.takePending().requests;
    expect(replayed).toMatchObject({
      input: {
        audience: "https://api.comma.test",
        conversations: { mode: "merge" },
        workspaces: { mode: "merge" },
      },
      operationId: "persist-1",
      workerGeneration: 2,
    });
    expect(
      queue.acceptAck({
        operationId: "persist-1",
        session: replayed!.input.session,
        workerGeneration: 2,
      })
    ).toEqual({ status: "accepted" });
    expect(queue.size).toBe(0);
  });

  it("rejects tiny operation and serialized-byte limits before cloning a new dirty write", () => {
    const input = productInboxWrite("replace");
    const serializedBytes =
      Buffer.byteLength("persist-1", "utf8") +
      Buffer.byteLength(JSON.stringify(input), "utf8");
    const clone = vi.spyOn(globalThis, "structuredClone");
    const operationLimited = new LocalDataDirtyReplayQueue(() => true, {
      maxDirtyBytes: serializedBytes * 2,
      maxDirtyOperations: 1,
    });

    operationLimited.enqueue("persist-1", input);
    expect(clone).toHaveBeenCalledTimes(1);
    expect(() => operationLimited.enqueue("persist-2", input)).toThrow(
      "operation limit (1)"
    );
    expect(clone).toHaveBeenCalledTimes(1);
    expect(operationLimited.size).toBe(1);
    expect(operationLimited.serializedBytes).toBe(serializedBytes);

    const byteLimited = new LocalDataDirtyReplayQueue(() => true, {
      maxDirtyBytes: serializedBytes,
      maxDirtyOperations: 2,
    });
    byteLimited.enqueue("persist-1", input);
    expect(clone).toHaveBeenCalledTimes(2);
    expect(() => byteLimited.enqueue("persist-2", input)).toThrow(
      `serialized-byte limit (${serializedBytes})`
    );
    expect(clone).toHaveBeenCalledTimes(2);
    expect(byteLimited.size).toBe(1);

    operationLimited.startWorker(1);
    expect(operationLimited.takePending(1).requests).toMatchObject([
      { operationId: "persist-1" },
    ]);
    byteLimited.startWorker(1);
    const [request] = byteLimited.takePending(1).requests;
    expect(
      byteLimited.acceptAck({
        operationId: request!.operationId,
        session: request!.input.session,
        workerGeneration: request!.workerGeneration,
      })
    ).toEqual({ status: "accepted" });
    expect(byteLimited.serializedBytes).toBe(0);
    expect(() => byteLimited.enqueue("persist-2", input)).not.toThrow();
    expect(byteLimited.discard("persist-2")).toBe(true);
    expect(byteLimited.serializedBytes).toBe(0);

    let currentSession = input.session;
    const staleLimited = new LocalDataDirtyReplayQueue(
      (session) => sameSessionProductLease(session, currentSession),
      {
        maxDirtyBytes: serializedBytes,
        maxDirtyOperations: 1,
      }
    );
    staleLimited.enqueue("persist-1", input);
    currentSession = {
      ...currentSession,
      generation: currentSession.generation + 1,
      sessionId: "session-b",
    };
    expect(staleLimited.startWorker(1)).toHaveLength(1);
    expect(staleLimited.serializedBytes).toBe(0);
  });

  it("rejects a non-normalized audience before a dirty write can be queued", () => {
    const queue = new LocalDataDirtyReplayQueue(() => true);
    const input = productInboxWrite("merge");
    input.audience = " ";

    expect(() => queue.enqueue("persist-invalid", input)).toThrow("non-empty string");
    expect(queue.size).toBe(0);
  });

  it("drops stale leases at ingress, dequeue, ack, and restart without changing write mode", () => {
    let current: SessionProductLease = productInboxWrite("merge").session;
    const isCurrent = (lease: SessionProductLease) =>
      sameSessionProductLease(lease, current);
    const staleSession = {
      ...current,
      generation: current.generation + 1,
      sessionId: "session-b",
    };

    const ingress = new LocalDataDirtyReplayQueue(isCurrent);
    current = staleSession;
    expect(() => ingress.enqueue("stale-ingress", productInboxWrite("merge"))).toThrow(
      LocalDataWriteFailure
    );
    expect(ingress.size).toBe(0);

    current = productInboxWrite("merge").session;
    const dequeue = new LocalDataDirtyReplayQueue(isCurrent);
    dequeue.enqueue("stale-dequeue", productInboxWrite("merge"));
    dequeue.startWorker(1);
    current = staleSession;
    expect(dequeue.takePending()).toMatchObject({
      requests: [],
      stale: [{ input: { workspaces: { mode: "merge" } } }],
    });
    expect(dequeue.size).toBe(0);

    current = productInboxWrite("replace").session;
    const acknowledgement = new LocalDataDirtyReplayQueue(isCurrent);
    acknowledgement.enqueue("stale-ack", productInboxWrite("replace"));
    acknowledgement.startWorker(1);
    const [request] = acknowledgement.takePending().requests;
    current = staleSession;
    expect(
      acknowledgement.acceptAck({
        operationId: "stale-ack",
        session: request!.input.session,
        workerGeneration: 1,
      })
    ).toMatchObject({
      dirty: { input: { workspaces: { mode: "replace" } } },
      status: "stale",
    });
    expect(acknowledgement.size).toBe(0);

    current = productInboxWrite("merge").session;
    const restart = new LocalDataDirtyReplayQueue(isCurrent);
    restart.enqueue("stale-restart", productInboxWrite("merge"));
    restart.startWorker(1);
    restart.takePending();
    current = staleSession;
    expect(restart.startWorker(2)).toMatchObject([
      { input: { workspaces: { mode: "merge" } } },
    ]);
    expect(restart.takePending().requests).toEqual([]);
  });
});

describe("LocalDataUtilityRepository", () => {
  it("caps persistent worker-open churn with exponential restart backoff", async () => {
    const host = new FakeWorkerHost({
      failingOpenConnections: [0, 1, 2, 3, 4, 5, 6],
    });
    const restarts = new ManualRestartScheduler();
    const repository = await LocalDataUtilityRepository.open({
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
      scheduleRestart: (restart, delayMs) => restarts.schedule(restart, delayMs),
    });

    expect(restarts.pendingDelays).toEqual([250]);
    for (const expectedDelay of [1_000, 5_000, 15_000, 30_000, 30_000]) {
      expect(restarts.pendingCount).toBe(1);
      restarts.runNext();
      await waitForMicrotasks();
      expect(restarts.pendingDelays).toEqual([expectedDelay]);
    }
    expect(repository.health()).toMatchObject({
      error: "injected open failure",
      status: "degraded",
    });
    await repository.close();
  });

  it("escalates short crash loops and resets backoff after a stable worker", async () => {
    const host = new FakeWorkerHost();
    const restarts = new ManualRestartScheduler();
    let now = 0;
    const repository = await LocalDataUtilityRepository.open({
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
      now: () => now,
      scheduleRestart: (restart, delayMs) => restarts.schedule(restart, delayMs),
    });

    host.connections[0]?.crash(new Error("short crash 1"));
    expect(restarts.pendingDelays).toEqual([250]);
    restarts.runNext();
    await waitForMicrotasks();

    host.connections[1]?.crash(new Error("short crash 2"));
    expect(restarts.pendingDelays).toEqual([1_000]);
    restarts.runNext();
    await waitForMicrotasks();

    now = 5_000;
    host.connections[2]?.crash(new Error("stable worker stopped"));
    expect(restarts.pendingDelays).toEqual([250]);
    await repository.close();
  });

  it("bounds an unresponsive initial open and recovers on a replacement worker", async () => {
    const host = new FakeWorkerHost({ hangingOpenConnections: [0] });
    const deadlines = new ManualDeadlineScheduler();
    const restarts = new ManualRestartScheduler();
    const opening = LocalDataUtilityRepository.open({
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
      openTimeoutMs: 25,
      requestTimeoutMs: 25,
      scheduleDeadline: (expire, delayMs) => deadlines.schedule(expire, delayMs),
      scheduleRestart: (restart) => restarts.schedule(restart),
    });
    let settled = false;
    void opening.finally(() => {
      settled = true;
    });

    await waitForMicrotasks();
    expect(settled).toBe(false);
    expect(host.connections[0]?.openInputs).toEqual([
      {
        databasePath: "/tmp/comma-local-data.sqlite",
        workerGeneration: 1,
      },
    ]);
    expect(deadlines.pendingDelays).toEqual([25]);

    deadlines.runNext();
    const repository = await opening;
    expect(repository.health()).toEqual({
      error: "Local data utility open timed out after 25 ms.",
      status: "degraded",
      workerGeneration: 1,
    });
    expect(host.connections[0]?.disposed).toBe(true);
    expect(restarts.pendingCount).toBe(1);

    const recovered = vi.fn();
    repository.onRecovered(recovered);
    restarts.runNext();
    await waitForMicrotasks();

    expect(host.connections[1]?.openInputs).toEqual([
      {
        databasePath: "/tmp/comma-local-data.sqlite",
        workerGeneration: 2,
      },
    ]);
    expect(repository.health()).toEqual({
      status: "ready",
      workerGeneration: 2,
    });
    expect(recovered).toHaveBeenCalledOnce();
    expect(recovered).toHaveBeenCalledWith(2);
    await repository.close();
  });

  it("bounds a hung write, replays it after restart, and ignores the late old-worker ack", async () => {
    const host = new FakeWorkerHost();
    const deadlines = new ManualDeadlineScheduler();
    const restarts = new ManualRestartScheduler();
    let operationSequence = 0;
    const repository = await LocalDataUtilityRepository.open({
      createOperationId: () => `persist-timeout-${++operationSequence}`,
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
      openTimeoutMs: 25,
      requestTimeoutMs: 25,
      scheduleDeadline: (expire, delayMs) => deadlines.schedule(expire, delayMs),
      scheduleRestart: (restart) => restarts.schedule(restart),
    });
    const first = host.connections[0]!;
    const timedOutWrite = repository.applyProductInboxSync(productInboxWrite("merge"));
    const rejection = expect(timedOutWrite).rejects.toThrow(
      "Local data utility applyProductInboxSync timed out after 25 ms."
    );
    expect(first.writeRequests).toHaveLength(1);

    deadlines.runNext();
    await rejection;
    expect(repository.health()).toEqual({
      error: "Local data utility applyProductInboxSync timed out after 25 ms.",
      status: "degraded",
      workerGeneration: 1,
    });
    expect(first.disposed).toBe(true);
    expect(restarts.pendingCount).toBe(1);

    first.acknowledge(0);
    await waitForMicrotasks();
    restarts.runNext();
    await waitForMicrotasks();

    const second = host.connections[1]!;
    expect(second.writeRequests).toHaveLength(1);
    expect(second.writeRequests[0]).toMatchObject({
      input: { workspaces: { mode: "merge" } },
      operationId: "persist-timeout-1",
      workerGeneration: 2,
    });
    second.acknowledge(0);
    await waitForMicrotasks();

    const nextWrite = repository.applyProductInboxSync(productInboxWrite("replace"));
    expect(second.writeRequests).toHaveLength(2);
    second.acknowledge(1);
    await expect(nextWrite).resolves.toMatchObject({
      operationId: "persist-timeout-2",
      workerGeneration: 2,
    });
    expect(repository.health()).toEqual({
      status: "ready",
      workerGeneration: 2,
    });
    await repository.close();
  });

  it("drains dirty writes through a fixed two-call concurrency window", async () => {
    const host = new FakeWorkerHost();
    const restarts = new ManualRestartScheduler();
    let operationSequence = 0;
    const repository = await LocalDataUtilityRepository.open({
      createOperationId: () => `persist-window-${++operationSequence}`,
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
      scheduleRestart: (restart) => restarts.schedule(restart),
    });
    host.connections[0]!.crash(new Error("injected recovery"));
    const writes = Array.from({ length: 5 }, () =>
      repository.applyProductInboxSync(productInboxWrite("replace"))
    );
    expect(host.connections[0]!.writeRequests).toEqual([]);

    restarts.runNext();
    await waitForMicrotasks();
    const connection = host.connections[1]!;

    expect(connection.writeRequests.map(({ operationId }) => operationId)).toEqual([
      "persist-window-1",
      "persist-window-2",
    ]);

    for (let index = 0; index < writes.length; index += 1) {
      connection.acknowledge(index);
      await waitForMicrotasks();
      expect(connection.writeRequests).toHaveLength(Math.min(writes.length, index + 3));
    }

    await expect(Promise.all(writes)).resolves.toHaveLength(5);
    expect(connection.writeRequests.map(({ operationId }) => operationId)).toEqual([
      "persist-window-1",
      "persist-window-2",
      "persist-window-3",
      "persist-window-4",
      "persist-window-5",
    ]);
    await repository.close();
  });

  it("pulls the next dirty write after an in-window worker failure", async () => {
    const host = new FakeWorkerHost();
    let operationSequence = 0;
    const repository = await LocalDataUtilityRepository.open({
      createOperationId: () => `persist-failure-${++operationSequence}`,
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
    });
    const writes = Array.from({ length: 3 }, () =>
      repository.applyProductInboxSync(productInboxWrite("merge"))
    );
    const firstRejection = expect(writes[0]).rejects.toThrow("injected write failure");
    const connection = host.connections[0]!;
    expect(connection.writeRequests).toHaveLength(2);

    connection.reject(0, new Error("injected write failure"));
    await firstRejection;
    await waitForMicrotasks();
    expect(connection.writeRequests).toHaveLength(3);

    connection.acknowledge(1);
    connection.acknowledge(2);
    await expect(Promise.all(writes.slice(1))).resolves.toHaveLength(2);
    await repository.close();
  });

  it("increments workerGeneration and replays an unconfirmed dirty write after a crash", async () => {
    const host = new FakeWorkerHost();
    const scheduler = new ManualRestartScheduler();
    const repository = await LocalDataUtilityRepository.open({
      createOperationId: () => "persist-1",
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
      scheduleRestart: (restart) => scheduler.schedule(restart),
    });
    const recovered = vi.fn();
    repository.onRecovered(recovered);

    const input = productInboxWrite("merge");
    const persisted = repository.applyProductInboxSync(input);
    input.workspaces.mode = "replace";

    const first = host.connections[0]!;
    expect(first.openInputs).toEqual([
      {
        databasePath: "/tmp/comma-local-data.sqlite",
        workerGeneration: 1,
      },
    ]);
    expect(first.writeRequests).toHaveLength(1);
    expect(first.writeRequests[0]).toMatchObject({
      input: {
        audience: "https://api.comma.test",
        workspaces: { mode: "merge" },
      },
      operationId: "persist-1",
      workerGeneration: 1,
    });

    first.crash(new Error("worker crashed"));
    expect(repository.health()).toEqual({
      error: "worker crashed",
      status: "degraded",
      workerGeneration: 1,
    });
    scheduler.runNext();
    await waitForMicrotasks();

    const second = host.connections[1]!;
    expect(second.openInputs[0]?.workerGeneration).toBe(2);
    expect(second.writeRequests[0]).toMatchObject({
      input: {
        audience: "https://api.comma.test",
        workspaces: { mode: "merge" },
      },
      operationId: "persist-1",
      workerGeneration: 2,
    });

    first.acknowledge(0);
    let settled = false;
    void persisted.finally(() => {
      settled = true;
    });
    await waitForMicrotasks();
    expect(settled).toBe(false);

    second.acknowledge(0);
    await expect(persisted).resolves.toEqual({
      operationId: "persist-1",
      session: input.session,
      workerGeneration: 2,
    });
    expect(repository.health()).toEqual({
      status: "ready",
      workerGeneration: 2,
    });
    expect(recovered).toHaveBeenCalledWith(2);

    await repository.close();
    expect(second.disposed).toBe(true);
  });

  it("keeps mandatory audience on typed read calls and rejects pending writes on close", async () => {
    const host = new FakeWorkerHost();
    const repository = await LocalDataUtilityRepository.open({
      createOperationId: () => "persist-close",
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: () => true,
    });

    await repository.listProductInboxItems({
      audience: "https://api.comma.test",
      principalId: "principal-a",
    });
    expect(host.connections[0]?.listInputs).toEqual([
      {
        audience: "https://api.comma.test",
        principalId: "principal-a",
      },
    ]);

    const persisted = repository.applyProductInboxSync(productInboxWrite("replace"));
    const rejection = expect(persisted).rejects.toThrow(
      "Local data repository is closed"
    );
    await repository.close();
    await rejection;
    expect(repository.health()).toEqual({
      status: "closed",
      workerGeneration: 1,
    });
  });

  it("rejects stale ingress and late worker acknowledgements with a typed local failure", async () => {
    const host = new FakeWorkerHost();
    let current: SessionProductLease = productInboxWrite("merge").session;
    const repository = await LocalDataUtilityRepository.open({
      createOperationId: (() => {
        let sequence = 0;
        return () => `persist-stale-${++sequence}`;
      })(),
      databasePath: "/tmp/comma-local-data.sqlite",
      host,
      isCurrentSessionLease: (lease) => sameSessionProductLease(lease, current),
    });
    const input = productInboxWrite("merge");
    const persisted = repository.applyProductInboxSync(input);
    expect(host.connections[0]?.writeRequests).toHaveLength(1);

    current = {
      ...current,
      generation: current.generation + 1,
      sessionId: "session-b",
    };
    host.connections[0]?.acknowledge(0);
    await expect(persisted).rejects.toMatchObject({
      code: "stale_session_lease",
      session: input.session,
    });

    await expect(
      repository.applyProductInboxSync(productInboxWrite("replace"))
    ).rejects.toBeInstanceOf(LocalDataWriteFailure);
    expect(host.connections[0]?.writeRequests).toHaveLength(1);
    await repository.close();
  });
});

describe("local-data MessagePort channel", () => {
  it("notifies close observers and tears down every listener", () => {
    const port = new FakeMessagePort();
    const channel = createAsyncCallMessagePortChannel(port);
    const closed = vi.fn();
    channel.onClose(closed);
    const messageListener = vi.fn();
    channel.on(messageListener);

    port.emitMessage({ operationId: "persist-1" });
    expect(messageListener).toHaveBeenCalledWith({ operationId: "persist-1" });
    expect(port.listenerCount("message")).toBe(1);
    expect(port.listenerCount("close")).toBe(1);

    port.emitClose();
    expect(closed).toHaveBeenCalledWith(expect.any(LocalDataRpcClosedError));
    expect(port.listenerCount("message")).toBe(0);
    expect(port.listenerCount("close")).toBe(0);
    expect(() => channel.send({})).toThrow(LocalDataRpcClosedError);
  });

  it("closes the underlying port exactly once", () => {
    const port = new FakeMessagePort();
    const channel = createAsyncCallMessagePortChannel(port);

    channel.close();
    channel.close();

    expect(port.closeCalls).toBe(1);
    expect(port.listenerCount("message")).toBe(0);
    expect(port.listenerCount("close")).toBe(0);
  });
});

class FakeWorkerHost implements LocalDataWorkerHost {
  readonly connections: FakeWorkerConnection[] = [];
  readonly #failingOpenConnections: Set<number>;
  readonly #hangingOpenConnections: Set<number>;

  constructor({
    failingOpenConnections = [],
    hangingOpenConnections = [],
  }: {
    failingOpenConnections?: number[] | undefined;
    hangingOpenConnections?: number[] | undefined;
  } = {}) {
    this.#failingOpenConnections = new Set(failingOpenConnections);
    this.#hangingOpenConnections = new Set(hangingOpenConnections);
  }

  connect() {
    const connection = new FakeWorkerConnection({
      openError: this.#failingOpenConnections.has(this.connections.length)
        ? new Error("injected open failure")
        : undefined,
      openHangs: this.#hangingOpenConnections.has(this.connections.length),
    });
    this.connections.push(connection);
    return connection;
  }
}

class FakeWorkerConnection implements LocalDataWorkerConnection {
  readonly #openError: Error | undefined;
  readonly #terminatedListeners = new Set<(error: Error) => void>();
  readonly #writeSettlements: Array<{
    reject: (error: Error) => void;
    resolve: (value: {
      operationId: string;
      session: ProductInboxCacheApplyInput["session"];
      workerGeneration: number;
    }) => void;
  }> = [];
  disposed = false;
  listInputs: Array<{
    audience: string;
    limit?: number | undefined;
    principalId: string;
    workspaceId?: string | undefined;
  }> = [];
  openInputs: LocalDataOpenInput[] = [];
  readonly #openHangs: boolean;
  terminated = false;
  writeRequests: LocalDataWriteRequest[] = [];

  constructor({
    openError,
    openHangs = false,
  }: {
    openError?: Error | undefined;
    openHangs?: boolean | undefined;
  } = {}) {
    this.#openError = openError;
    this.#openHangs = openHangs;
  }

  readonly remote: LocalDataWorkerConnection["remote"] = {
    applyProductInboxSync: (request) => {
      this.writeRequests.push(structuredClone(request));
      return new Promise((resolve, reject) => {
        this.#writeSettlements.push({ reject, resolve });
      });
    },
    close: async () => {},
    listProductInboxItems: async (input) => {
      this.listInputs.push(structuredClone(input));
      return [];
    },
    listProductWorkspaces: async () => [],
    open: async (input) => {
      this.openInputs.push(structuredClone(input));
      if (this.#openError) throw this.#openError;
      if (this.#openHangs) {
        return new Promise(() => {});
      }
      return {
        schemaVersion: 9,
        workerGeneration: input.workerGeneration,
      };
    },
    referencedBlobIds: async () => [],
    schemaVersion: async () => 9,
  };

  acknowledge(index: number) {
    const request = this.writeRequests[index]!;
    this.#writeSettlements[index]?.resolve({
      operationId: request.operationId,
      session: request.input.session,
      workerGeneration: request.workerGeneration,
    });
  }

  reject(index: number, error: Error) {
    this.#writeSettlements[index]?.reject(error);
  }

  crash(error: Error) {
    if (this.terminated) return;
    this.terminated = true;
    for (const listener of this.#terminatedListeners) listener(error);
  }

  dispose() {
    this.disposed = true;
    this.terminated = true;
    this.#terminatedListeners.clear();
  }

  isTerminated() {
    return this.terminated;
  }

  onTerminated(listener: (error: Error) => void) {
    this.#terminatedListeners.add(listener);
    return () => {
      this.#terminatedListeners.delete(listener);
    };
  }
}

class ManualRestartScheduler {
  readonly #scheduled: Array<{
    cancelled: boolean;
    delayMs: number;
    restart: () => void;
  }> = [];

  get pendingCount() {
    return this.#scheduled.filter((scheduled) => !scheduled.cancelled).length;
  }

  get pendingDelays() {
    return this.#scheduled
      .filter((scheduled) => !scheduled.cancelled)
      .map((scheduled) => scheduled.delayMs);
  }

  schedule(restart: () => void, delayMs = 0) {
    const scheduled = { cancelled: false, delayMs, restart };
    this.#scheduled.push(scheduled);
    return () => {
      scheduled.cancelled = true;
    };
  }

  runNext() {
    const scheduled = this.#scheduled.shift();
    if (!scheduled || scheduled.cancelled) {
      throw new Error("No local-data restart is scheduled.");
    }
    scheduled.restart();
  }
}

class ManualDeadlineScheduler {
  readonly #scheduled: Array<{
    cancelled: boolean;
    delayMs: number;
    expire: () => void;
  }> = [];

  get pendingDelays() {
    return this.#scheduled
      .filter((scheduled) => !scheduled.cancelled)
      .map((scheduled) => scheduled.delayMs);
  }

  schedule(expire: () => void, delayMs: number) {
    const scheduled = { cancelled: false, delayMs, expire };
    this.#scheduled.push(scheduled);
    return () => {
      scheduled.cancelled = true;
    };
  }

  runNext() {
    while (this.#scheduled.length > 0) {
      const scheduled = this.#scheduled.shift()!;
      if (scheduled.cancelled) continue;
      scheduled.expire();
      return;
    }
    throw new Error("No local-data deadline is scheduled.");
  }
}

class FakeUtilityParentPort implements LocalDataUtilityParentPort {
  #listener:
    | ((event: { data: unknown; ports: AsyncCallMessagePort[] }) => void)
    | undefined;

  once(
    _event: "message",
    listener: (event: { data: unknown; ports: AsyncCallMessagePort[] }) => void
  ) {
    this.#listener = listener;
  }

  emit(event: { data: unknown; ports: AsyncCallMessagePort[] }) {
    const listener = this.#listener;
    this.#listener = undefined;
    listener?.(event);
  }
}

class FakeMessagePort implements AsyncCallMessagePort {
  readonly #closeListeners = new Set<() => void>();
  readonly #messageListeners = new Set<(event: { data: unknown }) => void>();
  closeCalls = 0;
  started = false;

  close() {
    this.closeCalls += 1;
  }

  off(
    event: "close" | "message",
    listener: (() => void) | ((event: { data: unknown }) => void)
  ) {
    if (event === "close") this.#closeListeners.delete(listener as () => void);
    else this.#messageListeners.delete(listener as (event: { data: unknown }) => void);
  }

  on(
    event: "close" | "message",
    listener: (() => void) | ((event: { data: unknown }) => void)
  ) {
    if (event === "close") this.#closeListeners.add(listener as () => void);
    else this.#messageListeners.add(listener as (event: { data: unknown }) => void);
  }

  postMessage() {}

  start() {
    this.started = true;
  }

  emitClose() {
    for (const listener of this.#closeListeners) listener();
  }

  emitMessage(data: unknown) {
    for (const listener of this.#messageListeners) listener({ data });
  }

  listenerCount(event: "close" | "message") {
    return event === "close" ? this.#closeListeners.size : this.#messageListeners.size;
  }
}

function productInboxWrite(mode: "merge" | "replace"): ProductInboxCacheApplyInput {
  return {
    audience: "https://api.comma.test",
    conversations: {
      items: [
        {
          audience: "https://api.comma.test",
          groupId: "grp_1",
          id: "cnv_1",
          kind: "agent_task",
          principalId: "principal-a",
          raw: { group_id: "grp_1", id: "cnv_1" },
          status: "working",
          title: "Task",
          updatedAt: 20,
          workspaceId: "wsp_1",
        },
      ],
      mode,
      workspaceId: "wsp_1",
    },
    principalId: "principal-a",
    session: {
      audience: "https://api.comma.test",
      authorityInstanceId: "authority-a",
      generation: 1,
      sessionId: "session-a",
    },
    workspaces: {
      items: [
        {
          audience: "https://api.comma.test",
          groupId: "grp_1",
          id: "wsp_1",
          name: "Workspace",
          principalId: "principal-a",
          raw: { group_id: "grp_1", id: "wsp_1", name: "Workspace" },
        },
      ],
      mode,
    },
  };
}

function tempDatabasePath() {
  const dir = mkdtempSync(join(tmpdir(), "comma-local-data-worker-"));
  tempDirs.push(dir);
  return join(dir, "comma.sqlite");
}

async function waitForMicrotasks() {
  for (let pass = 0; pass < 10; pass += 1) {
    await Promise.resolve();
  }
}
