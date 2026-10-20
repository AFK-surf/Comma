import { flush } from "@comma/test-utils/fake-clock";
import { act, renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
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
// The page's clock is the core's: the test ticks it.
let tick = 0;
let core = createScriptedCore();
const scriptCore = () => {
  tick = 0;
  core = createScriptedCore({
    values: (topic) => (topic.topic === "computeTick" ? { tick } : undefined),
  });
  return { wrapper: ({ children }: { children: ReactNode }) => core.wrap(children) };
};
const tickCore = async () => {
  tick += 1;
  core.changed("computeTick");
  await flush();
};
afterEach(() => {
  vi.restoreAllMocks();
  mock.overview.mockReset();
  mock.workloads.mockReset();
});

it("bounds visible reads, leaves pagination to the user, and withdraws old cloud detail while retaining local management", async () => {
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
    { initialProps: { visible: true }, ...scriptCore() }
  );
  await flush();
  // A tick while the first read is out reads nothing more.
  await tickCore();
  expect(mock.overview).toHaveBeenCalledTimes(1);
  await act(async () => {
    release(page);
  });
  hidden = true;
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await tickCore();
  await tickCore();
  expect(mock.overview).toHaveBeenCalledTimes(1);
  // Shown again, it reads at once.
  hidden = false;
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await flush();
  expect(mock.overview).toHaveBeenCalledTimes(2);
  await tickCore();
  expect(mock.overview).toHaveBeenCalledTimes(3);
  expect(mock.overview.mock.calls.every(([input]) => !input.cursor)).toBe(true);
  act(() => result.current.open());
  const environment = () =>
    result.current.overview?.environments.find((row) => row.key === "opaque-A");
  let finishWork!: (result: LocalComputeWorkloads) => void;
  mock.workloads.mockImplementation(
    () =>
      new Promise<LocalComputeWorkloads>((done) => {
        finishWork = done;
      })
  );
  act(() => {
    result.current.select("opaque-A");
    void result.current.readWorkloads("opaque-A");
    void result.current.readWorkloads("opaque-A");
  });
  expect(mock.workloads).toHaveBeenCalledTimes(1);
  await act(async () => {
    mock.listener?.({ confirmationId: "B" } as ComputeNodeState);
    finishWork({ workloads: [{ label: "private-A", state: "ready" }] });
  });
  expect(environment()?.canReadWorkloads).toBe(false);
  expect(environment()?.canDisposeLocal).toBe(true);
  expect(result.current.cloudWorkloads).toBeUndefined();
  await act(async () => result.current.nextPage());
  expect(mock.overview).toHaveBeenLastCalledWith({
    workspaceId: "workspace",
    cursor: "next-page",
  });
  rerender({ visible: false });
  const count = mock.overview.mock.calls.length;
  await tickCore();
  await tickCore();
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
    !!result.current.data?.environments.some((row) => row.key === "opaque-A")
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
    !!result.current.data?.environments.some((row) => row.key === "opaque-A")
  ).toBe(false);
  act(() => mock.listener?.({ confirmationId: "new-login" } as ComputeNodeState));
  expect(result.current.maintenance.state?.operation?.requestId).toBe("local-task");
});
