import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  CommaNativeBridge,
  DriveCatalogQueryResult,
  DriveCatalogState,
} from "@comma/native-bridge";
import { DriveStore } from "../driveStore";
import type { DriveSynchronicityBackend } from "../driveSynchronicityBackend";
import { useDriveCatalogMentions } from "../useDriveCatalogMentions";

function page(name: string, revision = 1): DriveCatalogQueryResult {
  return {
    state: { status: "ready", revision },
    reset: false,
    items: [
      {
        spaceId: "drive",
        spaceName: "Drive",
        entry: {
          path: `deep/${name}`,
          kind: "file",
          origin: "own",
          contentRoot: name,
          mtimeMs: 1,
          size: 1,
          versions: 1,
        },
      },
    ],
  };
}
function setup() {
  let changed: ((state: DriveCatalogState) => void) | undefined;
  const query = vi.fn(
    async (): Promise<DriveCatalogQueryResult> => page("existing.txt")
  );
  const unsubscribe = vi.fn();
  globalThis.commaNative = {
    platform: "electron",
    os: "macos",
    driveCatalog: {
      query,
      state: {
        subscribe: (listener: (state: DriveCatalogState) => void) => {
          changed = listener;
          return unsubscribe;
        },
      },
    },
  } as unknown as CommaNativeBridge;
  const store = new DriveStore({ files: [], spaces: [], devices: [] });
  const readFile = vi.fn(async () => new Blob(["x"]));
  const backend = { readFile } as unknown as DriveSynchronicityBackend;
  const hook = renderHook(() => useDriveCatalogMentions(store, backend));
  return {
    ...hook,
    query,
    store,
    readFile,
    unsubscribe,
    change: (state: DriveCatalogState) => changed?.(state),
  };
}
afterEach(() => {
  globalThis.commaNative = undefined;
});

describe("Drive queries from the composer", () => {
  it("loads on @ open with an empty Drive store and reads bytes only after selection", async () => {
    const { result, query, store, readFile } = setup();
    expect(query).not.toHaveBeenCalled();
    act(() => result.current.onMenuQueryChange(""));
    await waitFor(() =>
      expect(result.current.items[0]?.file.name).toBe("existing.txt")
    );
    expect(query).toHaveBeenLastCalledWith({ query: "", limit: 5, refresh: true });
    expect(store.getSnapshot().files).toEqual([]);
    expect(readFile).not.toHaveBeenCalled();
    await result.current.items[0]!.read();
    expect(readFile).toHaveBeenCalledOnce();
  });

  it("refreshes for a Main commit while open, debounces global search and ignores obsolete responses", async () => {
    const { result, query, change } = setup();
    act(() => result.current.onMenuQueryChange(""));
    await waitFor(() => expect(result.current.items).toHaveLength(1));
    query.mockResolvedValueOnce(page("generated.txt", 2));
    act(() => change({ status: "ready", revision: 2 }));
    await waitFor(() =>
      expect(result.current.items[0]?.file.name).toBe("generated.txt")
    );
    let resolve!: (value: DriveCatalogQueryResult) => void;
    query.mockImplementationOnce(
      () =>
        new Promise((done) => {
          resolve = done;
        })
    );
    act(() => result.current.browse.onQueryChange("old"));
    await waitFor(() => expect(resolve).toBeDefined());
    query.mockResolvedValueOnce(page("new.txt"));
    act(() => {
      result.current.browse.onQueryChange("n");
      result.current.browse.onQueryChange("new");
    });
    await waitFor(() =>
      expect(result.current.browse.items[0]?.file.name).toBe("new.txt")
    );
    act(() => resolve(page("old.txt")));
    expect(result.current.browse.items[0]?.file.name).toBe("new.txt");
    expect(query).toHaveBeenLastCalledWith({ query: "new", limit: 50, refresh: true });
  });

  it("shows failures, retries explicitly, and releases demand when the menu closes", async () => {
    const { result, query, unsubscribe } = setup();
    query.mockRejectedValueOnce(new Error("node offline"));
    act(() => result.current.onMenuQueryChange(""));
    await waitFor(() => expect(result.current.error).toBe("node offline"));
    expect(result.current.status).toBe("ready");
    act(() => result.current.retry());
    await waitFor(() => expect(result.current.items).toHaveLength(1));
    expect(result.current.error).toBeUndefined();
    expect(query).toHaveBeenLastCalledWith({ query: "", limit: 5, retry: true });
    act(() => result.current.onMenuQueryChange(null));
    expect(unsubscribe).toHaveBeenCalledOnce();
  });
});
