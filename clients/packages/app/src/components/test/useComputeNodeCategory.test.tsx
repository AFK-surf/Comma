import { flush } from "@comma/test-utils/fake-clock";
import { act, renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ComputeNodeState, HostMaintenanceState } from "@comma/native-bridge";

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
  useActiveWorkspaceId: () => "workspace",
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
import { useComputeSettingsController } from "../useComputeSettingsController";
const installed: HostMaintenanceState = {
  installation: "installed",
  selectedReleaseId: "release",
  updateAvailable: false,
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
  vi.clearAllMocks();
});

it("starts the component update for missing capability without enabling a new connection", async () => {
  mock.state = {
    ...mock.state,
    status: "action_required",
    issue: "capability_missing",
  };
  // The native confirmation is still open.
  mock.maintain.mockReturnValue(new Promise(() => {}));
  const { result } = renderHook(() => useComputeSettingsController(true, true));
  await act(async () => {});
  await act(async () => result.current.primary());
  expect(result.current.detail).toBe("maintenance");
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "update",
    dataPolicy: "preserve",
  });
  expect(mock.configure).not.toHaveBeenCalled();
});
it("returns from the steps page when every step it showed in progress is ready", async () => {
  mock.state = { ...mock.state, status: "not_set", desiredEnabled: false };
  const { result, rerender } = renderHook(() =>
    useComputeSettingsController(true, true)
  );
  await act(async () => {});
  act(() => result.current.setDetail("setup"));
  mock.state = {
    ...mock.state,
    status: "processing",
    setup: { components: "ready", connection: "connecting", shell: "not_initialized" },
  };
  rerender();
  expect(result.current.detail).toBe("setup");
  mock.state = {
    ...mock.state,
    status: "ready",
    setup: { components: "ready", connection: "ready", shell: "ready" },
  };
  rerender();
  expect(result.current.detail).toBeUndefined();
});
it("reads the node on each tick while the visible steps page waits", async () => {
  let tick = 0;
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "computeTick" ? { tick } : undefined),
  });
  const wrapper = ({ children }: { children: ReactNode }) => core.wrap(children);
  mock.state = {
    ...mock.state,
    status: "processing",
    setup: { components: "ready", connection: "ready", shell: "preparing" },
  };
  const { result } = renderHook(() => useComputeSettingsController(true, true), {
    wrapper,
  });
  await act(async () => {});
  act(() => result.current.setDetail("setup"));
  await act(async () => {});
  const before = mock.refresh.mock.calls.length;
  tick += 1;
  core.changed("computeTick");
  await act(() => flush());
  // Without this read the finished Shell step shows only after a manual status check.
  expect(mock.refresh.mock.calls.length).toBeGreaterThan(before);
});
it("shows a failed component setup's own error under the generic reason", async () => {
  mock.state = {
    ...mock.state,
    status: "action_required",
    issue: "preparation_failed",
    preparation: {
      source: "download",
      location: "https://example.test/Host.zip",
      instance: "shared",
      phase: "failed",
      error: "Host download failed (HTTP 404).",
    },
  };
  const { result } = renderHook(() => useComputeSettingsController(true, true));
  await act(async () => {});
  expect(result.current.reason).toBe(
    "The compute components are not ready. Continue setup."
  );
  expect(result.current.reasonDetail).toBe("Host download failed (HTTP 404).");
});
it("invalidates connection confirmation during maintenance and confirms the workspace owner after completion", async () => {
  let finish!: (state: HostMaintenanceState) => void;
  mock.maintain.mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      })
  );
  const { result } = renderHook(() => useComputeSettingsController(true, true));
  await act(async () => {});
  act(() => result.current.openConfirm("drain"));
  expect(result.current.nodeOverlay).toBeDefined();
  let request!: Promise<HostMaintenanceState | undefined>;
  act(() => {
    request = result.current.local.maintenance.submit("reinstall");
  });
  expect(result.current.nodeOverlay).toBeUndefined();
  expect(result.current.workspaceUnconfirmed).toBe(true);
  let check!: (state: ComputeNodeState) => void;
  mock.refresh.mockImplementation(
    () =>
      new Promise((resolve) => {
        check = resolve;
      })
  );
  const complete = {
    ...installed,
    operation: {
      requestId: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
      action: "reinstall" as const,
      dataPolicy: "preserve" as const,
      phase: "completed" as const,
      outcome: "succeeded" as const,
    },
  };
  mock.read.mockResolvedValue(complete);
  await act(async () => {
    finish(complete);
    await request;
  });
  expect(result.current.workspaceUnconfirmed).toBe(true);
  await act(async () => {
    check(mock.state);
  });
  expect(result.current.workspaceUnconfirmed).toBe(false);
});
it("keeps a failed owner check unconfirmed until an explicit successful read", async () => {
  const { result } = renderHook(() => useComputeSettingsController(true, true));
  await act(async () => {});
  mock.refresh.mockResolvedValue(undefined);
  mock.read.mockResolvedValue({
    ...installed,
    operation: {
      requestId: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
      action: "reinstall",
      dataPolicy: "preserve",
      phase: "completed",
      outcome: "succeeded",
    },
  });
  await act(() => result.current.local.maintenance.refresh());
  expect(result.current.workspaceUnconfirmed).toBe(true);
  mock.refresh.mockImplementation(async () => mock.state);
  await act(async () => result.current.checkWorkspace());
  expect(result.current.workspaceUnconfirmed).toBe(false);
});
