import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaComputeProjection } from "../../api";
import { useComputeWorkloadsSection } from "../useComputeWorkloadsSection";

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  localStorage.clear();
});

it("bounds visible observation rounds and stops reads when the panel or document is hidden", async () => {
  vi.useFakeTimers();
  localStorage.setItem("comma.activeWorkspaceId", "wsp_compute");
  let hidden = false;
  vi.spyOn(document, "hidden", "get").mockImplementation(() => hidden);
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
  const getCompute = vi.fn(async () => projection);
  const api = { getCompute } as unknown as CommaApiClient;
  const { rerender, unmount } = renderHook(
    ({ enabled }) => useComputeWorkloadsSection(api, enabled),
    {
      initialProps: { enabled: true },
    }
  );
  await act(async () => {});
  expect(getCompute).toHaveBeenCalledTimes(1);
  hidden = true;
  document.dispatchEvent(new Event("visibilitychange"));
  await act(async () => {
    await vi.advanceTimersByTimeAsync(60_000);
  });
  expect(getCompute).toHaveBeenCalledTimes(1);
  hidden = false;
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  expect(getCompute).toHaveBeenCalledTimes(2);
  for (let round = 2; round < 60; round += 1) {
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
  }
  expect(getCompute).toHaveBeenCalledTimes(60);
  await act(async () => {
    await vi.advanceTimersByTimeAsync(300_000);
  });
  expect(getCompute).toHaveBeenCalledTimes(60);
  rerender({ enabled: false });
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(300_000);
  });
  expect(getCompute).toHaveBeenCalledTimes(60);
  unmount();
});
