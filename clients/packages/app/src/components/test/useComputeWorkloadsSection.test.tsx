import { createScriptedCore, resolvedWorkspace } from "@comma/test-utils/scripted-core";
import { act, render, renderHook, screen, waitFor } from "@comma/test-utils/render";
import type { ReactNode } from "react";
import { afterEach, expect, it, vi } from "vitest";
import type {
  ComputeProjection as CommaComputeProjection,
  ComputeWorkload,
} from "@comma/core/contract";
import { useComputeWorkloadsSection } from "../useComputeWorkloadsSection";

afterEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

const projection: CommaComputeProjection = {
  environments: [
    {
      id: "env_compute",
      desired_state: "ready",
      observed_state: "ready",
      can_create: true,
    },
  ],
  workloads: [
    {
      id: "workload_pending",
      environment_id: "env_compute",
      kind: "shell",
      desired_state: "ready",
      observed_state: "pending",
      phase: "waiting_connection",
    },
  ],
};

function scripted(answer?: (name: string, params: unknown) => unknown) {
  const watching: Record<string, unknown>[] = [];
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? resolvedWorkspace("wsp_compute")
        : topic.topic === "compute"
          ? {
              workspace: "wsp_compute",
              projection,
              error: false,
              creation: null,
              accepted: null,
            }
          : undefined,
    calls: (name, params) => {
      calls.push([name, params]);
      return answer
        ? answer(name, params)
        : name === "compute.create"
          ? projection.workloads[0]
          : null;
    },
    // The Compute reads (the workspace the app works in is the core's own).
    onSubscribe: (topic) => {
      if (topic.topic !== "workspace") watching.push(topic);
    },
    onUnsubscribe: (topic) => {
      if (topic.topic !== "workspace") watching.splice(watching.indexOf(topic), 1);
    },
  });
  const wrapper = ({ children }: { children: ReactNode }) => core.wrap(children);
  return { core, watching, calls, wrapper };
}

it("lets Compute go while the panel or the page is hidden, and lets the local node drive reads", async () => {
  let hidden = false;
  vi.spyOn(document, "hidden", "get").mockImplementation(() => hidden);
  const t = scripted();
  const { result, rerender } = renderHook(
    ({ enabled, tick }: { enabled: boolean; tick?: number }) =>
      useComputeWorkloadsSection(true, enabled, tick),
    {
      initialProps: { enabled: true } as { enabled: boolean; tick?: number },
      wrapper: t.wrapper,
    }
  );
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  expect(t.watching).toEqual([
    { topic: "compute", prefer: "wsp_compute", after: "", shared: "" },
  ]);

  hidden = true;
  act(() => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  expect(result.current.rows).toHaveLength(0);
  hidden = false;
  act(() => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));

  // With the local node available, its ticks ask the core for reads.
  rerender({ enabled: true, tick: 1 });
  await waitFor(() =>
    expect(t.calls.filter(([n]) => n === "compute.observe")).toHaveLength(1)
  );
  rerender({ enabled: true, tick: 2 });
  await waitFor(() =>
    expect(t.calls.filter(([n]) => n === "compute.observe")).toHaveLength(2)
  );
});

it("creates a Shell in the environment that can take one, and reports a refusal in words", async () => {
  const t = scripted();
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.canCreate).toBe(true));
  act(() => {
    result.current.openCreate();
    result.current.setName("Build box");
  });
  await act(() => result.current.create());
  expect(t.calls.filter(([n]) => n === "compute.create")).toEqual([
    [
      "compute.create",
      { workspace: "wsp_compute", environment: "env_compute", name: "Build box" },
    ],
  ]);
});

it("keeps recoverable and deleting workloads while omitting terminal accepted receipts", async () => {
  const t = scripted();
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  const accepted = (patch: Partial<ComputeWorkload>) => ({
    ...projection.workloads[0]!,
    id: "accepted",
    ...patch,
  });
  const emit = async (row: ComputeWorkload) => {
    await act(async () => {
      t.core.emit("compute", {
        workspace: "wsp_compute",
        projection,
        error: false,
        creation: null,
        accepted: row,
      });
    });
  };
  await emit(accepted({ phase: "action_required" }));
  expect(result.current.rows.map((w) => w.id)).toEqual([
    "accepted",
    "workload_pending",
  ]);
  await emit(
    accepted({
      deletion: {
        request_id: "delete-request",
        phase: "cleaning",
        error: "original_device_offline",
      },
    })
  );
  expect(result.current.rows[0]?.deletion?.error).toBe("original_device_offline");
  await emit(
    accepted({
      phase: "deleted",
      deletion: { request_id: "delete-request", phase: "complete" },
    })
  );
  expect(result.current.rows.map((w) => w.id)).toEqual(["workload_pending"]);
  await emit(
    accepted({
      phase: "cloud_retired",
      deletion: { request_id: "delete-request", phase: "cloud_retired" },
    })
  );
  expect(result.current.rows.map((w) => w.id)).toEqual(["workload_pending"]);
});

it("names an Agent VMM workload's device: this device, a listed device, or an own device", async () => {
  const t = scripted();
  const { result } = renderHook(
    () =>
      useComputeWorkloadsSection(true, true, undefined, {
        names: new Map([["dev_studio", "Studio Mac"]]),
        localId: "dev_here",
      }),
    { wrapper: t.wrapper }
  );
  const at = (device_id?: string) =>
    result.current.location({
      ...projection.workloads[0]!,
      location: { provider: "agent_vmm", ...(device_id ? { device_id } : {}) },
    });
  expect(at("dev_here")).toBe("This device");
  expect(at("dev_studio")).toBe("Studio Mac");
  expect(at("dev_gone")).toBe("Own device");
  expect(at()).toBe("Own device");
});

it("keeps a definite delete refusal only in its dialog and clears it when that dialog closes", async () => {
  const t = scripted((name) => {
    if (name === "compute.delete")
      throw { code: "business_owner_required", status: 409 };
    return null;
  });
  const row = { ...projection.workloads[0]!, generation: 1, name: "Build box" };
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  act(() => result.current.openDialog("delete", row));
  const overlay = render(result.current.overlay, { wrapper: t.wrapper });
  await act(async () =>
    screen.getByRole("button", { name: /^Delete(?: workload)?$/ }).click()
  );
  overlay.rerender(result.current.overlay);
  expect(screen.getByRole("alert").textContent).toContain("feature that owns it");
  expect(result.current.error).toBe("");
  expect(result.current.detailError).toBe("");
  expect(result.current.rowActionError).toBeUndefined();
  await act(async () => screen.getByRole("button", { name: "Cancel" }).click());
  expect(result.current.overlay).toBeUndefined();
  expect(result.current.error).toBe("");
});

it("scopes failed detail reads and recovers them through an exact retry without a page refresh", async () => {
  let up = false;
  const ready = { ...projection.workloads[0]!, phase: "ready", revision: 2 };
  const t = scripted((name) => {
    if (name === "compute.workload") {
      if (!up) throw { code: "network" };
      return ready;
    }
    return null;
  });
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  await act(async () => result.current.openWorkload(projection.workloads[0]!));
  await waitFor(() => expect(result.current.detailError).not.toBe(""));
  expect(result.current.error).toBe("");
  up = true;
  await act(async () => result.current.refreshDetail());
  await waitFor(() => expect(result.current.current?.phase).toBe("ready"));
  expect(result.current.detailError).toBe("");
  expect(result.current.current?.phase).toBe("ready");
  expect(t.calls.filter(([name]) => name === "compute.refresh")).toHaveLength(0);
  expect(t.calls.filter(([name]) => name === "compute.workload")).toHaveLength(2);
});

it("shows uncertain deletion feedback only for its target until the exact owner receipt converges", async () => {
  const t = scripted();
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  const row = {
    ...projection.workloads[0]!,
    generation: 1,
    revision: 1,
    phase: "ready",
  };
  const emit = async (uncertain: boolean, phase: string) =>
    act(async () => {
      t.core.emit("compute", {
        workspace: "wsp_compute",
        projection: { ...projection, workloads: [] },
        error: false,
        creation: null,
        accepted: null,
        deletion: {
          workloadId: row.id,
          requestId: "delete-original",
          generation: 1,
          uncertain,
          workload: {
            ...row,
            phase,
            deletion: uncertain
              ? null
              : { request_id: "delete-original", phase: "complete" },
          },
        },
      });
    });
  await emit(true, "ready");
  expect(result.current.rows[0]?.id).toBe(row.id);
  expect(result.current.rowActionError).toMatchObject({ id: row.id });
  expect(result.current.error).toBe("");
  await emit(false, "deleted");
  expect(result.current.rows).toHaveLength(0);
  expect(result.current.rowActionError).toBeUndefined();
});

it("keeps exact detail facts on equal list revisions while owner deletion receipts advance status", async () => {
  const row: ComputeWorkload = {
    ...projection.workloads[0]!,
    generation: 1,
    revision: 3,
    phase: "ready",
  };
  const detail: ComputeWorkload = {
    ...row,
    runtime_policy: { egress_mode: "public_internet", resources: { pid_max: 128 } },
    uses: [{ kind: "task", id: "task-one", label: "Build" }],
  };
  const t = scripted((name) => (name === "compute.workload" ? detail : null));
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  await act(async () =>
    t.core.emit("compute", {
      workspace: "wsp_compute",
      projection: { ...projection, workloads: [row] },
      error: false,
      creation: null,
      accepted: null,
    })
  );
  await act(async () => result.current.openWorkload(row));
  await waitFor(() =>
    expect(result.current.current?.runtime_policy).toEqual(detail.runtime_policy)
  );
  expect(result.current.current?.uses).toEqual(detail.uses);
  await act(async () =>
    t.core.emit("compute", {
      workspace: "wsp_compute",
      projection: { ...projection, workloads: [row] },
      error: false,
      creation: null,
      accepted: null,
      deletion: {
        workloadId: row.id,
        requestId: "delete-exact",
        generation: 1,
        uncertain: false,
        workload: {
          ...row,
          phase: "deleted",
          deletion: { request_id: "delete-exact", generation: 1, phase: "complete" },
        },
      },
    })
  );
  expect(result.current.current?.phase).toBe("deleted");
  expect(result.current.current?.runtime_policy).toEqual(detail.runtime_policy);
  expect(result.current.current?.uses).toEqual(detail.uses);
});

it("marks the first explicit Delete confirmation before any deletion projection is available", async () => {
  const row = { ...projection.workloads[0]!, generation: 2, name: "Build box" };
  const t = scripted((name) =>
    name === "compute.delete" ? { ...row, phase: "deleting" } : null
  );
  const { result } = renderHook(() => useComputeWorkloadsSection(true, true), {
    wrapper: t.wrapper,
  });
  await waitFor(() => expect(result.current.rows).toHaveLength(1));
  expect(result.current.legacyDeleteTargetId).toBeUndefined();
  act(() => result.current.openDialog("delete", row));
  render(result.current.overlay, { wrapper: t.wrapper });
  expect(t.calls.filter(([name]) => name === "compute.delete")).toHaveLength(0);
  await act(async () => screen.getByRole("button", { name: "Delete" }).click());
  expect(t.calls.filter(([name]) => name === "compute.delete")).toEqual([
    [
      "compute.delete",
      {
        workspace: "wsp_compute",
        id: row.id,
        generation: 2,
        confirmLegacy: true,
      },
    ],
  ]);
});
