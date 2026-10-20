import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import {
  ResourceCache,
  ResourceCacheContext,
  useResource,
  useStateFor,
} from "../src/resource";

/** A load whose calls resolve when the test says so. */
function deferredLoads<T>() {
  const pending: ((value: T) => void)[] = [];
  const load = () => new Promise<T>((resolve) => pending.push(resolve));
  return { load, resolve: (value: T) => pending.shift()?.(value), pending };
}

const withCache =
  (cache: ResourceCache) =>
  ({ children }: { children: ReactNode }) => (
    <ResourceCacheContext value={cache}>{children}</ResourceCacheContext>
  );

describe("ResourceCache", () => {
  it("misses, hits and evicts the least recently used entry", () => {
    const cache = new ResourceCache(2);
    expect(cache.get("a")).toBeUndefined();
    cache.set("a", 1);
    cache.set("b", 2);
    expect(cache.get("a")).toEqual({ data: 1 });
    cache.set("c", 3);
    expect(cache.peek("b")).toBeUndefined();
    expect(cache.peek("a")).toEqual({ data: 1 });
    expect(cache.peek("c")).toEqual({ data: 3 });
  });

  it("keeps the cached object when a new read is equal, and drops reads older than a clear", () => {
    const cache = new ResourceCache();
    const first = { rows: [1, 2] };
    cache.set("rows", first);
    expect(cache.set("rows", { rows: [1, 2] })).toBe(first);

    const version = cache.version;
    cache.clear();
    cache.set("rows", { rows: [1] }, version);
    expect(cache.peek("rows")).toBeUndefined();
  });
});

describe("useResource with a cache", () => {
  it("shows cached data at once on a new mount and replaces it with the new read", async () => {
    const cache = new ResourceCache();
    const loads = deferredLoads<string>();
    const wrapper = withCache(cache);

    const first = renderHook(() => useResource("k", loads.load), { wrapper });
    expect(first.result.current[0]).toMatchObject({ state: "loading" });
    act(() => loads.resolve("v1"));
    await waitFor(() =>
      expect(first.result.current[0]).toMatchObject({ state: "ready", data: "v1" })
    );
    first.unmount();

    const second = renderHook(() => useResource("k", loads.load), { wrapper });
    expect(second.result.current[0]).toMatchObject({ state: "ready", data: "v1" });
    await waitFor(() => expect(loads.pending.length).toBeGreaterThan(0));
    act(() => loads.resolve("v2"));
    await waitFor(() =>
      expect(second.result.current[0]).toMatchObject({ state: "ready", data: "v2" })
    );
  });

  it("retry() skips the cache and shows loading until the new read", async () => {
    const cache = new ResourceCache();
    cache.set("k", "stale");
    const loads = deferredLoads<string>();
    const { result } = renderHook(() => useResource("k", loads.load), {
      wrapper: withCache(cache),
    });
    await waitFor(() => expect(loads.pending.length).toBeGreaterThan(0));
    act(() => loads.resolve("fresh"));
    await waitFor(() =>
      expect(result.current[0]).toMatchObject({ state: "ready", data: "fresh" })
    );

    act(() => result.current[1]());
    expect(result.current[0]).toMatchObject({ state: "loading" });
    expect(cache.peek("k")).toBeUndefined();
    act(() => loads.resolve("after write"));
    await waitFor(() =>
      expect(result.current[0]).toMatchObject({ state: "ready", data: "after write" })
    );
    expect(cache.peek("k")).toEqual({ data: "after write" });
  });

  it("refresh() keeps the current data on screen while it reads again", async () => {
    const loads = deferredLoads<string>();
    const { result } = renderHook(() => useResource("k", loads.load));
    await waitFor(() => expect(loads.pending.length).toBeGreaterThan(0));
    act(() => loads.resolve("v1"));
    await waitFor(() =>
      expect(result.current[0]).toMatchObject({ state: "ready", data: "v1" })
    );

    act(() => result.current[2]());
    expect(result.current[0]).toMatchObject({ state: "ready", data: "v1" });
    await waitFor(() => expect(loads.pending.length).toBeGreaterThan(0));
    act(() => loads.resolve("v2"));
    await waitFor(() =>
      expect(result.current[0]).toMatchObject({ state: "ready", data: "v2" })
    );
  });
});

/** A load whose calls settle when the test says so. */
function controlledLoads<T>() {
  const pending: { resolve: (value: T) => void; reject: (error: unknown) => void }[] =
    [];
  const load = () =>
    new Promise<T>((resolve, reject) => pending.push({ resolve, reject }));
  return { load, pending };
}

describe("useResource failures", () => {
  it("a failed refresh() keeps the data shown and its cache entry", async () => {
    const cache = new ResourceCache();
    const loads = controlledLoads<string>();
    const { result } = renderHook(() => useResource("k", loads.load), {
      wrapper: withCache(cache),
    });
    await waitFor(() => expect(loads.pending.length).toBe(1));
    act(() => loads.pending.shift()?.resolve("v1"));
    await waitFor(() =>
      expect(result.current[0]).toMatchObject({ state: "ready", data: "v1" })
    );

    act(() => result.current[2]());
    await waitFor(() => expect(loads.pending.length).toBe(1));
    await act(async () => loads.pending.shift()?.reject(new Error("503")));
    expect(result.current[0]).toMatchObject({ state: "ready", data: "v1" });
    expect(cache.peek("k")).toEqual({ data: "v1" });

    // retry() still shows the failure.
    act(() => result.current[1]());
    await waitFor(() => expect(loads.pending.length).toBe(1));
    await act(async () => loads.pending.shift()?.reject(new Error("503")));
    expect(result.current[0]).toMatchObject({ state: "error" });
  });

  it("a failed first read shows the error", async () => {
    const loads = controlledLoads<string>();
    const { result } = renderHook(() => useResource("k", loads.load));
    await waitFor(() => expect(loads.pending.length).toBe(1));
    await act(async () => loads.pending.shift()?.reject(new Error("503")));
    expect(result.current[0]).toMatchObject({ state: "error" });
  });
});

describe("useStateFor", () => {
  it("starts over when the basis changes and drops updates for an earlier one", () => {
    const first = { page: 1 };
    const { result, rerender } = renderHook(
      ({ basis }) => useStateFor<number[]>(basis, []),
      { initialProps: { basis: first as object } }
    );
    act(() => result.current[1]((rows) => [...rows, 2]));
    expect(result.current[0]).toEqual([2]);
    const stale = result.current[1];

    rerender({ basis: { page: 1 } });
    expect(result.current[0]).toEqual([]);
    act(() => stale((rows) => [...rows, 3]));
    expect(result.current[0]).toEqual([]);
    act(() => result.current[1]((rows) => [...rows, 4]));
    expect(result.current[0]).toEqual([4]);
  });
});
