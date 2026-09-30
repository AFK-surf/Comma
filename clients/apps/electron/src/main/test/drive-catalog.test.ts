import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  SynchronicityEntry,
  SynchronicityListInput,
  SynchronicityState,
} from "@comma/native-bridge";
import { DriveCatalogService } from "../modules/synchronicity/catalog";

const entry = (path: string, mtimeMs: number): SynchronicityEntry => ({
  path,
  mtimeMs,
  size: 1,
  kind: "file",
  origin: "own",
  contentRoot: path,
  versions: 1,
});
function fixture(files: SynchronicityEntry[]) {
  let changed: (() => void) | undefined;
  const spaces = ["drive", "remote"];
  const state = vi.fn(
    (): SynchronicityState => ({
      status: "ready",
      origin: "own",
      origins: ["own"],
      domain: "",
      dataDir: "",
      defaultSpace: "drive",
      deviceName: "Mac",
      localRoot: "",
      pins: [],
      spaces: spaces.map((id) => ({
        id,
        label: id === "remote" ? "共享" : "",
        autoAdopt: true,
        checkoutPath: "",
        heldSize: 0,
        replica: false,
        sourcePath: "",
        writable: true,
      })),
    })
  );
  const list = vi.fn(async (input: SynchronicityListInput) => {
    const rows = input.space === "drive" ? files : [entry("深层/计划.txt", 50000)];
    const start = input.cursor ? Number(input.cursor) : 0;
    const entries = rows.slice(start, start + input.limit!);
    const end = start + entries.length;
    return { entries, nextCursor: end < rows.length ? String(end) : "" };
  });
  const service = new DriveCatalogService({
    state,
    list,
    subscribeChanges: (listener) => {
      changed = listener;
      return () => {
        changed = undefined;
      };
    },
  });
  return { service, list, state, change: () => changed?.() };
}
const services: DriveCatalogService[] = [];
afterEach(() => {
  services.splice(0).forEach((service) => service.close());
});
async function ready(service: DriveCatalogService) {
  await vi.waitFor(() => expect(service.state().status).toBe("ready"));
}

describe("Drive mention catalog", () => {
  it("finds globally recent files beyond the first node page without per-query tree reads", async () => {
    const { service, list } = fixture(
      Array.from({ length: 1200 }, (_, i) => entry(`folder/file-${i}.txt`, i))
    );
    services.push(service);
    expect(service.query({ query: "", limit: 5 })).toMatchObject({
      items: [],
      state: { status: "loading" },
    });
    await ready(service);
    const first = service.query({ query: "", limit: 5 });
    expect(first.items.map((row) => row.entry.path)).toEqual([
      "深层/计划.txt",
      "folder/file-1199.txt",
      "folder/file-1198.txt",
      "folder/file-1197.txt",
      "folder/file-1196.txt",
    ]);
    expect(list).toHaveBeenCalledTimes(4);
    for (const [input] of list.mock.calls)
      expect(input).toMatchObject({ policy: "newest", limit: 500 });
    const page = service.query({ query: "", limit: 50, cursor: first.nextCursor! });
    expect(page.items).toHaveLength(50);
    expect(
      new Set([...first.items, ...page.items].map((row) => row.entry.path)).size
    ).toBe(55);
    expect(
      service
        .query({ query: "file-0.txt", limit: 5 })
        .items.map((row) => row.entry.path)
    ).toEqual(["folder/file-0.txt"]);
    expect(service.query({ query: "共享", limit: 5 }).items[0]?.entry.path).toBe(
      "深层/计划.txt"
    );
    expect(service.query({ query: "计", limit: 5 }).items[0]?.entry.path).toBe(
      "深层/计划.txt"
    );
    expect(list).toHaveBeenCalledTimes(4);
  });

  it("batches commits, reflects deletion, and resets a cursor after the catalog changes", async () => {
    const files = [entry("old.txt", 1), entry("keep.txt", 2)];
    const { service, list, change } = fixture(files);
    services.push(service);
    service.query({ query: "", limit: 1 });
    await ready(service);
    const first = service.query({ query: "", limit: 1 });
    files.splice(0, 1, entry("new.txt", 100000));
    change();
    change();
    change();
    await vi.waitFor(() => expect(service.state().revision).toBe(2));
    const next = service.query({ query: "", limit: 50, cursor: first.nextCursor! });
    expect(next.reset).toBe(true);
    expect(next.items.map((row) => row.entry.path)).toEqual([
      "new.txt",
      "深层/计划.txt",
      "keep.txt",
    ]);
    expect(list).toHaveBeenCalledTimes(4);
  });

  it("preserves the complete index on failure and retries only on explicit demand", async () => {
    const { service, list } = fixture([entry("keep.txt", 1)]);
    services.push(service);
    service.query({ query: "", limit: 5 });
    await ready(service);
    list.mockRejectedValueOnce(new Error("node disconnected"));
    service.query({ query: "", limit: 5, retry: true });
    await vi.waitFor(() => expect(service.state().status).toBe("error"));
    const failed = service.query({ query: "", limit: 5 });
    expect(failed.state.reason).toBe("node disconnected");
    expect(failed.items).toHaveLength(2);
    expect(list).toHaveBeenCalledTimes(3);
    service.query({ query: "", limit: 5, retry: true });
    await ready(service);
    expect(service.state().revision).toBe(1);
  });

  it("coalesces concurrent demand and includes a commit made during an older listing", async () => {
    const { service, list, change } = fixture([entry("before.txt", 1)]);
    services.push(service);
    let resolve!: (result: {
      entries: SynchronicityEntry[];
      nextCursor: string;
    }) => void;
    list.mockImplementationOnce(
      () =>
        new Promise((done) => {
          resolve = done;
        })
    );
    service.query({ query: "", limit: 5 });
    service.query({ query: "", limit: 50 });
    await vi.waitFor(() => expect(resolve).toBeDefined());
    change();
    resolve({ entries: [entry("stale.txt", 0)], nextCursor: "" });
    await vi.waitFor(() => expect(service.state().revision).toBe(2));
    expect(
      service.query({ query: "", limit: 50 }).items.map((row) => row.entry.path)
    ).toContain("before.txt");
    expect(list).toHaveBeenCalledTimes(4);
  });
  it("bounds sparse substring work and returns a continuation instead of a false empty result", async () => {
    const { service, list } = fixture(
      Array.from({ length: 5000 }, (_, i) => entry(`${i}-abc_bcz_cza_zab.txt`, i))
    );
    services.push(service);
    service.query({ query: "", limit: 5 });
    await ready(service);
    const before = list.mock.calls.length;
    const page = service.query({ query: "abczabc", limit: 5 });
    expect(page.items).toEqual([]);
    expect(page.nextCursor?.offset).toBe(2048);
    expect(list).toHaveBeenCalledTimes(before);
    const next = service.query({
      query: "abczabc",
      limit: 50,
      cursor: page.nextCursor!,
    });
    expect(next.nextCursor?.offset).toBe(4096);
    const last = service.query({
      query: "abczabc",
      limit: 50,
      cursor: next.nextCursor!,
    });
    expect(last.items).toEqual([]);
    expect(last.nextCursor).toBeUndefined();
  });

  it("ends a stalled read with an error and does not stack transport calls on retry", async () => {
    vi.useFakeTimers();
    try {
      const { service, list } = fixture([]);
      services.push(service);
      list.mockImplementationOnce(() => new Promise(() => {}));
      service.query({ query: "", limit: 5 });
      await vi.advanceTimersByTimeAsync(60_001);
      expect(service.state().status).toBe("error");
      expect(service.state().reason).toMatch(/timed out/);
      service.query({ query: "", limit: 5, retry: true });
      expect(list).toHaveBeenCalledOnce();
    } finally {
      vi.useRealTimers();
    }
  });

  it("revalidates external changes on open/focus demand without a completion-triggered scan loop", async () => {
    let clock = 0;
    const now = vi.spyOn(Date, "now").mockImplementation(() => clock);
    try {
      const files = [entry("before.txt", 1)];
      const { service, list } = fixture(files);
      services.push(service);
      service.query({ query: "", limit: 5, refresh: true });
      await ready(service);
      files.push(entry("external.txt", 100000));
      clock = 20_000;
      service.query({ query: "", limit: 5, refresh: true });
      await vi.waitFor(() => expect(service.state().revision).toBe(2));
      expect(service.query({ query: "", limit: 5 }).items[0]?.entry.path).toBe(
        "external.txt"
      );
      const reads = list.mock.calls.length;
      clock = 80_000;
      service.query({ query: "", limit: 5 });
      expect(list).toHaveBeenCalledTimes(reads);
      expect(service.state().status).toBe("ready");
    } finally {
      now.mockRestore();
    }
  });
});
