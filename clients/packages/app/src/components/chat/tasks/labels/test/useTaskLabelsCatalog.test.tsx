import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaTaskLabelCatalog } from "../../../../../api";
import {
  useTaskLabelsCatalog,
  useTaskLabelsCatalogStatus,
} from "../useTaskLabelsCatalog";

// Each read answers with a fresh object, as the network does.
function labelsApi(read: () => CommaTaskLabelCatalog) {
  const listTaskLabels = vi.fn(async () => structuredClone(read()));
  return { api: { listTaskLabels } as unknown as CommaApiClient, listTaskLabels };
}

function catalog(name: string): CommaTaskLabelCatalog {
  return {
    approval_policy: "ask",
    colors: ["red"],
    labels: [{ color: "red", id: "label-a", name }],
    proposals: [],
  };
}

describe("task labels catalog", () => {
  it("keeps readers' catalog and renders nothing when a reread confirms it", async () => {
    const { api, listTaskLabels } = labelsApi(() => catalog("Bug"));
    let renders = 0;
    const { result } = renderHook(() => {
      renders += 1;
      return useTaskLabelsCatalog(api, "grp-a");
    });
    await waitFor(() => expect(result.current.catalog?.labels[0]?.name).toBe("Bug"));
    const held = result.current.catalog;
    const rendersAfterFirstRead = renders;

    // A surface opening elsewhere rereads the Group's catalog.
    await act(() => result.current.refresh());

    expect(listTaskLabels).toHaveBeenCalledTimes(2);
    expect(result.current.catalog).toBe(held);
    expect(renders).toBe(rendersAfterFirstRead);
  });

  it("reports loading for the first read only and keeps labels through a failed reread", async () => {
    let fail = false;
    const { api } = labelsApi(() => {
      if (fail) throw new Error("offline");
      return catalog("Bug");
    });
    const loading: boolean[] = [];
    const { result } = renderHook(() => {
      const state = useTaskLabelsCatalogStatus(api, "grp-a");
      loading.push(state.loading);
      return state;
    });
    await waitFor(() => expect(result.current.catalog).toBeDefined());
    expect(loading).toContain(true);
    expect(result.current.loading).toBe(false);

    loading.length = 0;
    fail = true;
    await act(() => result.current.refresh());

    expect(loading).not.toContain(true);
    expect(result.current.error).toBe(true);
    expect(result.current.catalog?.labels[0]?.name).toBe("Bug");
  });

  it("hands a mutation's catalog to every reader of the Group", async () => {
    const { api } = labelsApi(() => catalog("Bug"));
    const panel = renderHook(() => useTaskLabelsCatalog(api, "grp-a"));
    const settings = renderHook(() => useTaskLabelsCatalogStatus(api, "grp-a"));
    await waitFor(() => expect(panel.result.current.catalog).toBeDefined());

    act(() => settings.result.current.replace(catalog("Defect")));

    expect(panel.result.current.catalog?.labels[0]?.name).toBe("Defect");
    expect(settings.result.current.catalog?.labels[0]?.name).toBe("Defect");
  });
});
