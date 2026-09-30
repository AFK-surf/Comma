import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LocalFilePreviewCache } from "../runtime-chat/channel/preview/LocalFilePreviewCache";
import type { ChatImagePreviewRef } from "../components/chat/model/conversationChannel";

type Deferred<Value> = {
  promise: Promise<Value>;
  resolve(value: Value): void;
};

const pngBytes = () =>
  Uint8Array.from([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
    1, 8, 4, 0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100,
    248, 15, 0, 1, 5, 1, 1, 39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
    130,
  ]);

const localFileRef = (index: number) => `lfi1_${index.toString(36).padStart(43, "0")}`;

const localPreviewRef = (ref: ChatImagePreviewRef) => {
  if (typeof ref !== "string") throw new Error("Expected a local preview ref.");
  return ref;
};

const deferred = <Value>(): Deferred<Value> => {
  let resolve!: (value: Value) => void;
  const promise = new Promise<Value>((settle) => {
    resolve = settle;
  });
  return { promise, resolve };
};

const flushMicrotasks = async () => {
  await Promise.resolve();
  await Promise.resolve();
};

describe("LocalFilePreviewCache", () => {
  let nextObjectUrl = 0;
  let createObjectURL: ReturnType<typeof vi.spyOn>;
  let revokeObjectURL: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    nextObjectUrl = 0;
    createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockImplementation(() => `blob:local-preview-${++nextObjectUrl}`);
    revokeObjectURL = vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("single-flights one ref and revokes its shared URL only after the final lease", async () => {
    const result = deferred<Uint8Array | undefined>();
    const load = vi.fn(() => result.promise);
    const cache = new LocalFilePreviewCache({ load });
    const ref = localFileRef(1);

    const firstPromise = cache.acquire(ref);
    const secondPromise = cache.acquire(ref);
    await flushMicrotasks();

    expect(load).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledWith(ref);

    result.resolve(pngBytes());
    const [first, second] = await Promise.all([firstPromise, secondPromise]);

    expect(first).toBeDefined();
    expect(second).toBeDefined();
    expect(first?.url).toBe(second?.url);
    expect(createObjectURL).toHaveBeenCalledOnce();

    first?.release();
    first?.release();
    await flushMicrotasks();
    expect(revokeObjectURL).not.toHaveBeenCalled();

    second?.release();
    await flushMicrotasks();
    expect(revokeObjectURL).toHaveBeenCalledOnce();
    expect(revokeObjectURL).toHaveBeenCalledWith(first?.url);

    cache.dispose();
  });

  it.each([
    ["PNG", "image/png", pngBytes()],
    [
      "GIF",
      "image/gif",
      Uint8Array.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3b]),
    ],
    [
      "WebP",
      "image/webp",
      Uint8Array.from([
        0x52, 0x49, 0x46, 0x46, 22, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38,
        0x58, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]),
    ],
  ])(
    "types the shared URL's blob from the %s bytes Main handed back",
    async (_case, type, bytes) => {
      const cache = new LocalFilePreviewCache({ load: vi.fn(async () => bytes) });

      const lease = await cache.acquire(localFileRef(1));

      expect(lease).toBeDefined();
      expect(createObjectURL).toHaveBeenCalledOnce();
      const blob = createObjectURL.mock.calls[0]?.[0];
      expect(blob).toBeInstanceOf(Blob);
      expect((blob as Blob).type).toBe(type);
      lease?.release();
    }
  );

  it("keeps the ready entry through a same-turn handoff and reloads after retirement", async () => {
    const load = vi.fn(async () => pngBytes());
    const cache = new LocalFilePreviewCache({ load });
    const ref = localFileRef(2);

    const composerLease = await cache.acquire(ref);
    expect(composerLease).toBeDefined();
    composerLease?.release();

    // A pending/canonical message mounts in the same React commit in which the
    // Composer attachment disappears. It must be able to retain the same URL
    // before the last-release microtask retires it.
    const messageLease = await cache.acquire(ref);
    await flushMicrotasks();

    expect(messageLease?.url).toBe(composerLease?.url);
    expect(load).toHaveBeenCalledOnce();
    expect(revokeObjectURL).not.toHaveBeenCalled();

    messageLease?.release();
    await flushMicrotasks();
    expect(revokeObjectURL).toHaveBeenCalledOnce();

    const reenteredLease = await cache.acquire(ref);
    expect(reenteredLease).toBeDefined();
    expect(reenteredLease?.url).not.toBe(composerLease?.url);
    expect(load).toHaveBeenCalledTimes(2);

    reenteredLease?.release();
    await flushMicrotasks();
    cache.dispose();
  });

  it("runs at most four distinct preview loads at once", async () => {
    const gates = new Map<string, Deferred<Uint8Array | undefined>>();
    let activeLoads = 0;
    let maximumActiveLoads = 0;
    const load = vi.fn((ref: ChatImagePreviewRef) => {
      activeLoads += 1;
      maximumActiveLoads = Math.max(maximumActiveLoads, activeLoads);
      const gate = deferred<Uint8Array | undefined>();
      gates.set(localPreviewRef(ref), gate);
      return gate.promise.finally(() => {
        activeLoads -= 1;
      });
    });
    const cache = new LocalFilePreviewCache({ load });
    const refs = Array.from({ length: 5 }, (_, index) => localFileRef(index + 10));
    const leases = refs.map((ref) => cache.acquire(ref));

    await flushMicrotasks();
    expect(load).toHaveBeenCalledTimes(4);
    expect(maximumActiveLoads).toBe(4);
    expect(gates.has(refs[4]!)).toBe(false);

    gates.get(refs[0]!)?.resolve(pngBytes());
    await vi.waitFor(() => expect(load).toHaveBeenCalledTimes(5));
    expect(maximumActiveLoads).toBe(4);

    for (const ref of refs.slice(1)) {
      gates.get(ref)?.resolve(pngBytes());
    }
    const resolvedLeases = await Promise.all(leases);
    for (const lease of resolvedLeases) lease?.release();
    await flushMicrotasks();
    cache.dispose();
  });

  it("removes abandoned queued acquisitions before they consume a loader slot", async () => {
    const gates = new Map<string, Deferred<Uint8Array | undefined>>();
    const load = vi.fn((ref: ChatImagePreviewRef) => {
      const gate = deferred<Uint8Array | undefined>();
      gates.set(localPreviewRef(ref), gate);
      return gate.promise;
    });
    const cache = new LocalFilePreviewCache({ load });
    const refs = Array.from({ length: 5 }, (_, index) => localFileRef(index + 20));
    const controllers = refs.map(() => new AbortController());
    const acquisitions = refs.map((ref, index) =>
      cache.acquire(ref, controllers[index]?.signal)
    );

    await flushMicrotasks();
    expect(load).toHaveBeenCalledTimes(4);
    expect(gates.has(refs[4]!)).toBe(false);

    controllers[4]?.abort();
    await expect(acquisitions[4]).resolves.toBeUndefined();
    gates.get(refs[0]!)?.resolve(pngBytes());
    const firstLease = await acquisitions[0];
    await flushMicrotasks();
    expect(load).toHaveBeenCalledTimes(4);

    const replacementRef = localFileRef(25);
    const replacement = cache.acquire(replacementRef);
    await vi.waitFor(() => expect(load).toHaveBeenCalledTimes(5));
    expect(gates.has(replacementRef)).toBe(true);

    for (const ref of [...refs.slice(1, 4), replacementRef]) {
      gates.get(ref)?.resolve(pngBytes());
    }
    firstLease?.release();
    for (const acquisition of acquisitions.slice(1, 4)) {
      (await acquisition)?.release();
    }
    (await replacement)?.release();
    await flushMicrotasks();
    cache.dispose();
  });

  it("admits at most fifty unique queued or loading refs", async () => {
    const gates = new Map<string, Deferred<Uint8Array | undefined>>();
    const load = vi.fn((ref: ChatImagePreviewRef) => {
      const gate = deferred<Uint8Array | undefined>();
      gates.set(localPreviewRef(ref), gate);
      return gate.promise;
    });
    const cache = new LocalFilePreviewCache({ load });
    const admittedRefs = Array.from({ length: 50 }, (_, index) =>
      localFileRef(index + 100)
    );
    const admitted = admittedRefs.map((ref) => cache.acquire(ref));
    const duplicate = cache.acquire(admittedRefs[0]!);

    await flushMicrotasks();
    expect(load).toHaveBeenCalledTimes(4);
    await expect(cache.acquire(localFileRef(150))).resolves.toBeUndefined();

    cache.dispose();
    await expect(Promise.all([...admitted, duplicate])).resolves.toEqual(
      Array.from({ length: 51 }, () => undefined)
    );

    for (const gate of gates.values()) gate.resolve(pngBytes());
    await flushMicrotasks();
    expect(createObjectURL).not.toHaveBeenCalled();
  });

  it("keeps sixty mounted image leases without starving later loads and releases every URL", async () => {
    const load = vi.fn(async () => pngBytes());
    const cache = new LocalFilePreviewCache({ load });
    const leases = [];
    for (let index = 0; index < 60; index += 1) {
      const lease = await cache.acquire(localFileRef(index));
      expect(lease).toBeDefined();
      leases.push(lease!);
    }
    expect(load).toHaveBeenCalledTimes(60);
    expect(revokeObjectURL).not.toHaveBeenCalled();
    const repeated = await cache.acquire(localFileRef(0));
    expect(repeated?.url).toBe(leases[0]!.url);
    expect(load).toHaveBeenCalledTimes(60);
    repeated!.release();
    for (const lease of leases) lease.release();
    await flushMicrotasks();
    expect(revokeObjectURL).toHaveBeenCalledTimes(60);
    cache.dispose();
    expect(revokeObjectURL).toHaveBeenCalledTimes(60);
  });

  it("disposes ready, queued, and in-flight entries and discards late results", async () => {
    const gates = new Map<string, Deferred<Uint8Array | undefined>>();
    const load = vi.fn((ref: ChatImagePreviewRef) => {
      const gate = deferred<Uint8Array | undefined>();
      gates.set(localPreviewRef(ref), gate);
      return gate.promise;
    });
    const cache = new LocalFilePreviewCache({ load });
    const refs = Array.from({ length: 6 }, (_, index) => localFileRef(index + 200));
    const acquisitions = refs.map((ref) => cache.acquire(ref));

    await flushMicrotasks();
    expect(load).toHaveBeenCalledTimes(4);

    gates.get(refs[0]!)?.resolve(pngBytes());
    const readyLease = await acquisitions[0];
    await vi.waitFor(() => expect(load).toHaveBeenCalledTimes(5));
    expect(readyLease).toBeDefined();
    expect(createObjectURL).toHaveBeenCalledOnce();
    expect(gates.has(refs[5]!)).toBe(false);

    cache.dispose();

    expect(revokeObjectURL).toHaveBeenCalledOnce();
    await expect(Promise.all(acquisitions.slice(1))).resolves.toEqual(
      Array.from({ length: 5 }, () => undefined)
    );
    await expect(cache.acquire(localFileRef(299))).resolves.toBeUndefined();
    expect(load).toHaveBeenCalledTimes(5);

    for (const gate of gates.values()) gate.resolve(pngBytes());
    await flushMicrotasks();
    expect(createObjectURL).toHaveBeenCalledOnce();

    readyLease?.release();
    readyLease?.release();
    expect(revokeObjectURL).toHaveBeenCalledOnce();
  });

  it("does not negatively cache loader rejection or an unavailable result", async () => {
    const load = vi
      .fn<() => Promise<Uint8Array | undefined>>()
      .mockRejectedValueOnce(new Error("preview failed"))
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce(pngBytes());
    const cache = new LocalFilePreviewCache({ load });
    const ref = localFileRef(300);

    await expect(cache.acquire(ref)).resolves.toBeUndefined();
    await expect(cache.acquire(ref)).resolves.toBeUndefined();
    const lease = await cache.acquire(ref);

    expect(load).toHaveBeenCalledTimes(3);
    expect(lease).toBeDefined();
    lease?.release();
    await flushMicrotasks();
    cache.dispose();
  });
});
