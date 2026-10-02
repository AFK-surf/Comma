import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ComputeNodeState, HostMaintenanceState } from "@comma/native-bridge";
import type { SettingsPanelItem } from "@comma/ui";
import type { CommaApiClient } from "../../api";

const mock = vi.hoisted(() => ({
  state: {} as ComputeNodeState,
  read: vi.fn(),
  maintain: vi.fn(),
  refresh: vi.fn(),
  configure: vi.fn(),
  creation: false,
}));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
vi.mock("../activeWorkspace", () => ({
  readActiveWorkspaceId: () => "workspace",
  subscribeActiveWorkspace: () => () => {},
}));
vi.mock("../useComputeNode", () => ({
  useComputeNode: () => ({
    available: true,
    pending: false,
    state: mock.state,
    refresh: mock.refresh,
    configure: mock.configure,
  }),
}));
vi.mock("../useComputeWorkloadsSection", () => ({
  useComputeWorkloadsSection: () => ({
    workspaceName: "Workspace A",
    close: vi.fn(),
    section: {
      id: "compute-node.workloads",
      title: "Workloads",
      items: [
        { id: "compute-node.workload.private", title: "Private Shell" },
        ...(mock.creation
          ? [
              {
                id: "compute-node.creation",
                title: "Creation result is not yet confirmed",
              },
            ]
          : []),
      ],
    },
  }),
}));
vi.mock("../useComputeRecoverySection", () => ({
  useComputeRecoverySection: () => ({
    section: { id: "compute-node.recovery", title: "Recovery", items: [] },
  }),
}));
const bridge = {
  platform: "electron",
  computeNode: {
    state: { subscribe: () => () => {} },
    hostMaintenanceState: mock.read,
    maintainHost: mock.maintain,
    localOverview: async () => ({ availability: "available", environments: [] }),
  },
};
import { useComputeNodeCategory } from "../useComputeNodeCategory";
const installed: HostMaintenanceState = {
  installation: "installed",
  selectedReleaseId: "release",
  updateAvailable: false,
};
const press = (item: SettingsPanelItem | undefined) => {
  if (item?.control?.type !== "button") throw new Error("Expected button");
  item.control.onPress?.();
};
beforeEach(() => {
  mock.creation = false;
  mock.state = {
    status: "ready",
    confirmationId: "session-a",
    desiredEnabled: true,
    observationFresh: true,
    bindingWorkspaceId: "workspace",
    eligibility: { eligible: true },
    facets: {},
  } as ComputeNodeState;
  mock.refresh.mockImplementation(async () => mock.state);
  mock.read.mockResolvedValue(installed);
  mock.maintain.mockResolvedValue(installed);
});
afterEach(() => {
  vi.useRealTimers();
  vi.clearAllMocks();
});

it("shows three summaries and a single selected detail, with workload rows only in the workspace view", async () => {
  const { result } = renderHook(() =>
    useComputeNodeCategory({} as CommaApiClient, true)
  );
  await act(async () => {});
  expect(result.current.sections.map((s) => s.id)).toEqual([
    "compute-node.host",
    "compute-node.local-resources",
    "compute-node.workspace",
  ]);
  expect(
    result.current.sections
      .flatMap((s) => s.items)
      .some((i) => i.id === "compute-node.workload.private")
  ).toBe(false);
  const rootRow = (id: string) =>
    result.current.sections.flatMap((s) => s.items).find((i) => i.id === id);
  act(() => press(rootRow("compute-node.binding")));
  expect(result.current.detail?.id).toBe("compute-workspace");
  expect(
    result.current.detail?.sections?.some((s) => s.id === "compute-node.recovery")
  ).toBe(false);
  expect(
    result.current.detail?.sections
      ?.flatMap((s) => s.items)
      .some((i) => i.id === "compute-node.workload.private")
  ).toBe(true);
  act(() => {
    result.current.detail?.onBack?.();
    press(rootRow("compute-node.local-disk"));
  });
  expect(result.current.detail?.id).toBe("local-compute-management");
  act(() => result.current.detail?.onBack?.());
  expect(result.current.detail).toBeUndefined();
});

it("makes missing capability an update action rather than a status check or enable", async () => {
  mock.state = {
    ...mock.state,
    status: "action_required",
    issue: "capability_missing",
  } as ComputeNodeState;
  const { result } = renderHook(() =>
    useComputeNodeCategory({} as CommaApiClient, true)
  );
  await act(async () => {});
  const refreshes = mock.refresh.mock.calls.length;
  act(() => press(result.current.sections[0]!.items[0]));
  expect(result.current.detail?.id).toBe("compute-host-maintenance");
  const submit = result.current.detail?.sections
    ?.flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.host-submit");
  await act(async () => press(submit));
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "update",
    dataPolicy: "preserve",
  });
  expect(mock.configure).not.toHaveBeenCalled();
  expect(mock.refresh).toHaveBeenCalledTimes(refreshes);
});

it("shows an unresolved creation once in the root and once in the selected workspace view", async () => {
  mock.creation = true;
  const { result } = renderHook(() =>
    useComputeNodeCategory({} as CommaApiClient, true)
  );
  await act(async () => {});
  expect(
    result.current.sections
      .flatMap((s) => s.items)
      .filter((i) => i.id === "compute-node.creation")
  ).toHaveLength(1);
  act(() =>
    press(
      result.current.sections
        .flatMap((s) => s.items)
        .find((i) => i.id === "compute-node.binding")
    )
  );
  expect(
    result.current.detail?.sections
      ?.flatMap((s) => s.items)
      .filter((i) => i.id === "compute-node.creation")
  ).toHaveLength(1);
});

const maintenanceReceipt = {
  requestId: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  action: "reinstall" as const,
  dataPolicy: "reset" as const,
  phase: "completed" as const,
  outcome: "succeeded" as const,
};
const workspaceStatus = (category: ReturnType<typeof useComputeNodeCategory>) =>
  category.sections
    .flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.status")!;

it("withdraws the old ready state and confirmation during maintenance, then checks the original owner once", async () => {
  vi.useFakeTimers();
  let finishMaintenance!: (state: HostMaintenanceState) => void;
  mock.maintain.mockImplementation(
    () =>
      new Promise<HostMaintenanceState>((resolve) => {
        finishMaintenance = resolve;
      })
  );
  const { result } = renderHook(() =>
    useComputeNodeCategory({} as CommaApiClient, true)
  );
  await act(async () => {});
  const actions = result.current.sections
    .flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.actions")!.control;
  if (actions?.type !== "menu") throw new Error("Expected connection menu");
  act(() => actions.items.find((i) => i.id === "drain")!.onPress());
  expect(result.current.overlay).toBeDefined();
  const menu = result.current.sections[0]!.items[1]!.control;
  if (menu?.type !== "menu") throw new Error("Expected maintenance entry");
  act(() => menu.items.find((i) => i.id === "maintenance")!.onPress());
  const maintenanceActions = result.current
    .detail!.sections!.flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.host-actions")!.control;
  if (maintenanceActions?.type !== "menu") throw new Error("Expected maintenance menu");
  act(() => maintenanceActions.items.find((i) => i.id === "reinstall")!.onPress());
  act(() =>
    press(
      result.current
        .detail!.sections!.flatMap((s) => s.items)
        .find((i) => i.id === "compute-node.host-submit")
    )
  );
  expect(result.current.overlay).toBeUndefined();
  expect(workspaceStatus(result.current).title).toBe(
    "Operation result is not yet confirmed"
  );
  const callsBeforeCompletion = mock.refresh.mock.calls.length;
  let finishCheck!: (state: ComputeNodeState) => void;
  mock.refresh.mockImplementation(
    () =>
      new Promise<ComputeNodeState>((resolve) => {
        finishCheck = resolve;
      })
  );
  const completed = { ...installed, operation: maintenanceReceipt };
  mock.read.mockResolvedValue(completed);
  await act(async () => {
    finishMaintenance(completed);
  });
  expect(mock.refresh).toHaveBeenCalledTimes(callsBeforeCompletion + 1);
  expect(workspaceStatus(result.current).title).toBe(
    "Operation result is not yet confirmed"
  );
  await act(async () => {
    mock.state = { ...mock.state, status: "stopped" };
    finishCheck(mock.state);
  });
  expect(workspaceStatus(result.current).title).toBe("Node disabled");
  await act(async () => {
    await vi.advanceTimersByTimeAsync(10_000);
  });
  expect(mock.refresh).toHaveBeenCalledTimes(callsBeforeCompletion + 1);
  vi.useRealTimers();
});

it("keeps a failed maintenance verification unconfirmed until an explicit owner check succeeds", async () => {
  const { result } = renderHook(() =>
    useComputeNodeCategory({} as CommaApiClient, true)
  );
  await act(async () => {});
  mock.refresh.mockResolvedValue(undefined);
  mock.read.mockResolvedValue({ ...installed, operation: maintenanceReceipt });
  const menu = result.current.sections[0]!.items[1]!.control;
  if (menu?.type !== "menu") throw new Error("Expected local menu");
  await act(async () => {
    menu.items.find((i) => i.id === "refresh")!.onPress();
  });
  expect(workspaceStatus(result.current).title).toBe(
    "Operation result is not yet confirmed"
  );
  mock.refresh.mockImplementation(async () => mock.state);
  await act(async () => press(workspaceStatus(result.current)));
  expect(workspaceStatus(result.current).title).toBe("Available for new work");
});

it("ignores a completed check from the previous Session while the new Session is still unconfirmed", async () => {
  const { result, rerender } = renderHook(() =>
    useComputeNodeCategory({} as CommaApiClient, true)
  );
  await act(async () => {});
  let finishOld!: (state: ComputeNodeState) => void;
  mock.refresh.mockImplementationOnce(
    () =>
      new Promise<ComputeNodeState>((resolve) => {
        finishOld = resolve;
      })
  );
  mock.read.mockResolvedValue({ ...installed, operation: maintenanceReceipt });
  const menu = result.current.sections[0]!.items[1]!.control;
  if (menu?.type !== "menu") throw new Error("Expected local menu");
  await act(async () => {
    menu.items.find((i) => i.id === "refresh")!.onPress();
  });
  const old = mock.state;
  let finishNew!: (state: ComputeNodeState) => void;
  mock.refresh.mockImplementationOnce(
    () =>
      new Promise<ComputeNodeState>((resolve) => {
        finishNew = resolve;
      })
  );
  await act(async () => {
    mock.state = { ...mock.state, confirmationId: "session-b" };
    rerender();
  });
  await act(async () => {
    finishOld(old);
  });
  expect(workspaceStatus(result.current).title).toBe(
    "Operation result is not yet confirmed"
  );
  await act(async () => {
    finishNew(mock.state);
  });
  expect(workspaceStatus(result.current).title).toBe("Available for new work");
});
