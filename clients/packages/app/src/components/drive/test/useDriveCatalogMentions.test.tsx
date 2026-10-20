import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { DriveSearchValue } from "@comma/core-client";
import { describe, expect, it } from "vitest";
import { DriveStore } from "../driveStore";
import { useDriveCatalogMentions } from "../useDriveCatalogMentions";

const item = (name: string) => ({
  spaceId: "drive",
  spaceName: "Drive",
  entry: {
    path: `deep/${name}`,
    kind: "file" as const,
    origin: "own",
    contentRoot: name,
    mtimeMs: 1,
    size: 1,
    versions: 1,
  },
});

/** The composer's Drive mentions over a core whose Drive search answers `search` for each topic shown. */
function setup(
  search: (topic: Record<string, unknown>) => DriveSearchValue | undefined
) {
  const asked: Record<string, unknown>[] = [];
  const left: Record<string, unknown>[] = [];
  const calls: string[] = [];
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "driveSearch" ? search(topic) : undefined),
    calls: (name) => {
      calls.push(name);
      return name === "drive.read"
        ? { bytes: new TextEncoder().encode("x"), mediaType: "text/plain" }
        : null;
    },
    onSubscribe: (topic) => topic.topic === "driveSearch" && asked.push(topic),
    onUnsubscribe: (topic) => topic.topic === "driveSearch" && left.push(topic),
  });
  const store = new DriveStore();
  const hook = renderHook(() => useDriveCatalogMentions(store, true), {
    wrapper: ({ children }) => core.wrap(children),
  });
  return { ...hook, core, store, asked, left, calls };
}

const ready = (names: string[], more = false): DriveSearchValue => ({
  status: "ready",
  revision: 1,
  items: names.map(item),
  more,
});

describe("Drive mentions in the composer", () => {
  it("asks the core's Drive search when @ opens, and reads bytes only after a file is chosen", async () => {
    const t = setup(() => ready(["existing.txt"]));
    expect(t.asked).toEqual([]);
    act(() => t.result.current.onMenuQueryChange(""));
    await waitFor(() =>
      expect(t.result.current.items[0]?.file.name).toBe("existing.txt")
    );
    expect(t.asked).toEqual([{ topic: "driveSearch", query: "", limit: "5" }]);
    expect(t.result.current.items[0]?.location).toBe("Drive / deep");
    expect(t.store.getSnapshot().files).toEqual([]);
    expect(t.calls).toEqual([]);
    await expect(
      t.result.current.items[0]!.read().then((blob) => blob.size)
    ).resolves.toBe(1);
    expect(t.calls).toEqual(["drive.read"]);
  });

  it("shows what the core says as it changes, lets a query typed past go, and pages the browse panel", async () => {
    let names = ["first.txt"];
    const t = setup((topic) =>
      topic.query === "new"
        ? ready(
            ["new.txt", "newer.txt"].slice(0, Number(topic.limit) > 50 ? 2 : 1),
            Number(topic.limit) <= 50
          )
        : ready(names)
    );
    act(() => t.result.current.onMenuQueryChange(""));
    await waitFor(() => expect(t.result.current.items).toHaveLength(1));
    names = ["generated.txt"];
    act(() => t.core.changed("driveSearch"));
    await waitFor(() =>
      expect(t.result.current.items[0]?.file.name).toBe("generated.txt")
    );

    act(() => t.result.current.browse.onQueryChange("n"));
    act(() => t.result.current.browse.onQueryChange("new"));
    await waitFor(() =>
      expect(t.result.current.browse.items[0]?.file.name).toBe("new.txt")
    );
    expect(t.left).toContainEqual({ topic: "driveSearch", query: "n", limit: "50" });
    expect(t.result.current.browse.more).toBe(true);
    act(() => t.result.current.browse.loadMore());
    await waitFor(() => expect(t.result.current.browse.items).toHaveLength(2));
    expect(t.asked).toContainEqual({
      topic: "driveSearch",
      query: "new",
      limit: "100",
    });
    expect(t.result.current.browse.more).toBe(false);
  });

  it("shows the core's failure, retries through it, and lets the search go when the menu closes", async () => {
    let value: DriveSearchValue = {
      status: "error",
      reason: "node offline",
      revision: 0,
      items: [],
      more: false,
    };
    const t = setup(() => value);
    act(() => t.result.current.onMenuQueryChange(""));
    await waitFor(() => expect(t.result.current.error).toBe("node offline"));
    expect(t.result.current.status).toBe("ready");
    act(() => t.result.current.retry());
    await waitFor(() => expect(t.calls).toEqual(["driveSearch.retry"]));
    value = ready(["back.txt"]);
    act(() => t.core.changed("driveSearch"));
    await waitFor(() => expect(t.result.current.items).toHaveLength(1));
    expect(t.result.current.error).toBeUndefined();
    act(() => t.result.current.onMenuQueryChange(null));
    await waitFor(() =>
      expect(t.left).toContainEqual({ topic: "driveSearch", query: "", limit: "5" })
    );
  });
});
