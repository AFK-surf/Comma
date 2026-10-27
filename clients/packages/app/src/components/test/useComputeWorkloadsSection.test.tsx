import { createScriptedCore, resolvedWorkspace } from "@comma/test-utils/scripted-core";
import { act, renderHook, waitFor } from "@comma/test-utils/render";
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

function scripted() {
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
      return name === "compute.create" ? projection.workloads[0] : null;
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
