import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import type {
  ComputeNodeState,
  LocalComputeOverview,
  LocalComputeWorkloads,
} from "@comma/native-bridge";

const mock = vi.hoisted(() => ({
  listener: undefined as ((state: ComputeNodeState) => void) | undefined,
  overview: vi.fn(),
  workloads: vi.fn(),
  maintenance: vi.fn().mockResolvedValue({
    installation: "installed",
    selectedReleaseId: "test",
    updateAvailable: false,
  }),
}));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
const bridge = {
  platform: "electron",
  computeNode: {
    state: {
      subscribe: (listener: (state: ComputeNodeState) => void) => {
        mock.listener = listener;
        listener({ confirmationId: "A" } as ComputeNodeState);
        return () => {
          mock.listener = undefined;
        };
      },
    },
    hostMaintenanceState: mock.maintenance,
    localOverview: mock.overview,
    localWorkloads: mock.workloads,
  },
};
import { useLocalComputeCategory } from "../useLocalComputeCategory";
const page: LocalComputeOverview = {
  availability: "available",
  environments: [
    {
      key: "opaque-A",
      label: "local-A",
      origin: "remote",
      state: "unknown",
      canReadWorkloads: true,
      canOperate: false,
      canDisposeLocal: true,
    },
  ],
  nextCursor: "next-page",
};
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  mock.overview.mockReset();
  mock.workloads.mockReset();
});

it("bounds visible reads, leaves pagination to the user, and withdraws old cloud detail while retaining local management", async () => {
  vi.useFakeTimers();
  let hidden = false;
  vi.spyOn(document, "hidden", "get").mockImplementation(() => hidden);
  let release!: (page: LocalComputeOverview) => void;
  mock.overview
    .mockImplementationOnce(
      () =>
        new Promise<LocalComputeOverview>((done) => {
          release = done;
        })
    )
    .mockResolvedValue(page);
  const { result, rerender } = renderHook(
    ({ visible }) => useLocalComputeCategory(visible, "workspace"),
    { initialProps: { visible: true } }
  );
  await act(async () => {
    await vi.advanceTimersByTimeAsync(20_000);
  });
  expect(mock.overview).toHaveBeenCalledTimes(1);
  await act(async () => {
    release(page);
  });
  hidden = true;
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(20_000);
  });
  expect(mock.overview).toHaveBeenCalledTimes(1);
  hidden = false;
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  expect(mock.overview).toHaveBeenCalledTimes(2);
  expect(mock.overview.mock.calls.every(([input]) => !input.cursor)).toBe(true);
  const manage = result.current.section.items[0]!.control;
  if (manage?.type !== "button") throw new Error("Local management entry unavailable");
  act(() => manage.onPress?.());
  const environment = () =>
    result.current.category
      .detail!.sections!.flatMap((section) => section.items)
      .find((row) => row.id === "local-environment.opaque-A")!;
  const menu = environment().control;
  if (menu?.type !== "menu") throw new Error("Local actions unavailable");
  let finishWork!: (result: LocalComputeWorkloads) => void;
  mock.workloads.mockImplementation(
    () =>
      new Promise<LocalComputeWorkloads>((done) => {
        finishWork = done;
      })
  );
  act(() => {
    menu.items.find((item) => item.id === "workloads")!.onPress();
    menu.items.find((item) => item.id === "workloads")!.onPress();
  });
  expect(mock.workloads).toHaveBeenCalledTimes(1);
  await act(async () => {
    mock.listener?.({ confirmationId: "B" } as ComputeNodeState);
    finishWork({ workloads: [{ label: "private-A", state: "ready" }] });
  });
  const withdrawn = environment().control;
  if (withdrawn?.type !== "menu") throw new Error("Local actions lost on login change");
  expect(withdrawn.items.some((item) => item.id === "workloads")).toBe(false);
  expect(withdrawn.items.some((item) => item.id === "delete")).toBe(true);
  const next = result.current.category
    .detail!.sections!.flatMap((section) => section.items)
    .find((row) => row.id === "compute-node.local-next")!.control;
  if (next?.type !== "button") throw new Error("Next page unavailable");
  await act(async () => {
    next.onPress?.();
  });
  expect(mock.overview).toHaveBeenLastCalledWith({
    workspaceId: "workspace",
    cursor: "next-page",
  });
  rerender({ visible: false });
  const count = mock.overview.mock.calls.length;
  await act(async () => {
    await vi.advanceTimersByTimeAsync(20_000);
  });
  expect(mock.overview).toHaveBeenCalledTimes(count);
});

it("keeps local maintenance across login changes and withdraws old environment data after a completed reset", async () => {
  mock.overview.mockResolvedValue(page);
  mock.maintenance.mockResolvedValue({
    installation: "installed",
    selectedReleaseId: "test",
    updateAvailable: false,
  });
  const { result } = renderHook(() => useLocalComputeCategory(true));
  await act(async () => {});
  act(() => result.current.open());
  expect(
    result.current.category.detail?.sections
      ?.flatMap((s) => s.items)
      .some((i) => i.id === "local-environment.opaque-A")
  ).toBe(true);
  mock.maintenance.mockResolvedValue({
    installation: "not_installed",
    selectedReleaseId: "test",
    updateAvailable: false,
    operation: {
      requestId: "local-task",
      action: "uninstall",
      dataPolicy: "reset",
      outcome: "succeeded",
      phase: "completed",
    },
  });
  await act(async () => {
    await result.current.maintenance.refresh();
  });
  expect(
    result.current.category.detail?.sections
      ?.flatMap((s) => s.items)
      .some((i) => i.id === "local-environment.opaque-A")
  ).toBe(false);
  act(() => mock.listener?.({ confirmationId: "new-login" } as ComputeNodeState));
  expect(result.current.maintenance.state?.operation?.requestId).toBe("local-task");
});
