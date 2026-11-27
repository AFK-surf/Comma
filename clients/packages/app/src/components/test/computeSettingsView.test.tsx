import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  type ComputeNodeState,
  type HostMaintenanceState,
  type LocalComputeOverview,
} from "@comma/native-bridge";

// The local compute card over a scripted node owner and maintenance owner.

const mock = vi.hoisted(() => ({
  state: {} as ComputeNodeState,
  host: {} as HostMaintenanceState,
  canManage: true,
  projectionMissing: false,
  observationPaused: false,
  rows: [] as Record<string, unknown>[],
  disk: undefined as LocalComputeOverview["disk"] | undefined,
  maintain: vi.fn(),
  read: vi.fn(),
  resume: vi.fn(),
  abandon: vi.fn(),
  refresh: vi.fn(),
  workloadRefresh: vi.fn(),
  configure: vi.fn(),
  remove: vi.fn(),
  reset: vi.fn(),
  continue: vi.fn(),
  dispose: vi.fn(),
  environments: [] as LocalComputeOverview["environments"],
  disposal: undefined as LocalComputeOverview["disposal"],
}));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
vi.mock("../activeWorkspace", () => ({
  useActiveWorkspaceId: () => "workspace",
}));
vi.mock("../useComputeNode", async (original) => ({
  ...(await original<object>()),
  useComputeNode: () => ({
    available: true,
    pending: false,
    state: mock.state,
    refresh: mock.refresh,
    abandon: mock.abandon,
    configure: mock.configure,
    remove: mock.remove,
    continue: mock.continue,
    drain: vi.fn(),
    reauthorize: vi.fn(),
    resetLocalRecord: mock.reset,
  }),
}));
vi.mock("../useComputeWorkloadsSection", () => ({
  useComputeWorkloadsSection: () => ({
    workspaceName: "Workspace A",
    close: vi.fn(),
    canManage: mock.projectionMissing ? false : mock.canManage,
    projection: mock.projectionMissing
      ? undefined
      : { environments: [], workloads: mock.rows, can_manage: mock.canManage },
    error: mock.projectionMissing ? "Could not refresh workloads" : "",
    rows: mock.rows,
    observationPaused: mock.observationPaused,
    pending: false,
    refresh: mock.workloadRefresh,
    openCreate: vi.fn(),
    workloadLabel: (item: { name?: string; id: string }) => item.name ?? item.id,
    stateLabel: (item: { phase?: string }) =>
      item.phase === "starting" ? "Preparing" : "Ready to use",
    location: () => "Own device",
    needsRetry: () => false,
    openWorkload: vi.fn(),
    openDialog: vi.fn(),
    deleteLabel: () => "Delete",
  }),
}));
vi.mock("../useComputeRecoverySection", () => ({
  useComputeRecoverySection: () => ({}),
}));
const installed: HostMaintenanceState = {
  installation: "installed",
  selectedReleaseId: "release",
  updateAvailable: false,
};
const failedRequest = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
const bridge = {
  platform: "electron",
  computeNode: {
    state: { subscribe: () => () => {} },
    hostMaintenanceState: mock.read,
    maintainHost: mock.maintain,
    resumeHostMaintenance: mock.resume,
    localOverview: async () => ({
      availability: "available",
      environments: mock.environments,
      ...(mock.disk ? { disk: mock.disk, collectedAt: "2026-10-05T13:00:00Z" } : {}),
      ...(mock.disposal ? { disposal: mock.disposal } : {}),
    }),
    disposeLocal: mock.dispose,
  },
};
import { useComputeSettingsController } from "../useComputeSettingsController";
import { ComputeSettingsView } from "../ComputeSettingsView";

function Harness() {
  const controller = useComputeSettingsController(true, true);
  return (
    <>
      <ComputeSettingsView controller={controller} />
      {controller.nodeOverlay}
    </>
  );
}

async function show() {
  render(<Harness />);
  await act(async () => {});
  return within(screen.getByRole("region", { name: "Sandbox" }));
}

beforeEach(() => {
  mock.environments = [
    {
      key: "local-env",
      label: "env-a",
      origin: "local",
      state: "vm_stopped",
      canDisposeLocal: true,
      canReadWorkloads: false,
      canOperate: false,
    },
  ];
  mock.canManage = true;
  mock.projectionMissing = false;
  mock.observationPaused = false;
  mock.rows = [];
  mock.disk = undefined;
  mock.disposal = undefined;
  mock.host = installed;
  mock.state = {
    status: "action_required",
    confirmationId: "session-a",
    desiredEnabled: true,
    observationFresh: true,
    bindingWorkspaceId: "workspace",
    bindingRegistrationId: "operation-1",
    bindingRevision: 3,
    revision: 3,
    eligibility: { eligible: true },
    observed: {
      host: "ready",
      connector: "degraded",
      readability: "readable",
      salix: "degraded",
    },
    facets: {
      connection: "disconnected",
      admission: "closed",
      installationHealth: "healthy",
      runtimeReadiness: "unavailable",
      workActivity: "idle",
    },
  };
  mock.refresh.mockImplementation(async () => mock.state);
  mock.configure.mockImplementation(async () => mock.state);
  mock.remove.mockImplementation(async () => mock.state);
  mock.reset.mockImplementation(async () => mock.state);
  mock.maintain.mockResolvedValue(installed);
  mock.read.mockImplementation(async () => mock.host);
  mock.abandon.mockResolvedValue(undefined);
});
afterEach(() => {
  vi.clearAllMocks();
});

it("reopens a failed remove with one reason and continues the original action", async () => {
  mock.state = {
    ...mock.state,
    problem: "removal_failed",
    primaryAction: "continue",
    currentRequest: { requestId: "remove-1", kind: "remove" },
  };
  const card = await show();
  expect(card.getAllByText(/Disconnect did not finish/i)).toHaveLength(1);
  await userEvent.click(card.getByRole("button", { name: "Continue removal" }));
  expect(mock.continue).toHaveBeenCalledTimes(1);
  expect(mock.configure).not.toHaveBeenCalled();
});

it("keeps the primary sandbox action available when cloud workloads fail to load", async () => {
  mock.projectionMissing = true;
  mock.state = {
    ...mock.state,
    problem: "continuation_paused",
    primaryAction: "continue",
    currentRequest: { requestId: "setup-1", kind: "configure" },
  };
  const card = await show();
  const button = card.getByRole("button", { name: "Continue enabling" });
  await userEvent.click(button);
  expect(mock.continue).toHaveBeenCalledTimes(1);
});

it("shows ready status and disk usage on the sandbox row when ready", async () => {
  mock.state = { ...mock.state, status: "ready", desiredEnabled: true };
  mock.disk = {
    usedBytes: "1503238554",
    capacityBytes: "68719476736",
    importReservationBytes: "0",
  };
  const card = await show();
  expect(card.getByText(/Ready, 1\.4 GiB used/)).toBeTruthy();
});

it("shows storage and maintenance sections in Sandbox storage & maintenance", async () => {
  mock.host = {
    ...installed,
    operation: {
      requestId: failedRequest,
      action: "update",
      dataPolicy: "preserve",
      phase: "installing",
      outcome: "pending",
    },
  };
  await show();
  await userEvent.click(
    screen.getByRole("button", { name: "Sandbox storage & maintenance" })
  );
  expect(screen.getByRole("heading", { name: "Storage" })).toBeTruthy();
  expect(screen.getByRole("heading", { name: "Maintenance & recovery" })).toBeTruthy();
  expect(screen.getByText("Updating sandbox components…")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Continue maintenance" })).toBeTruthy();
});

it("confirms Restart & repair, Reset environment, and Uninstall in-app before calling maintainHost", async () => {
  await show();
  await userEvent.click(
    screen.getByRole("button", { name: "Sandbox storage & maintenance" })
  );

  // 1. Restart & repair
  await userEvent.click(screen.getByRole("button", { name: "Restart & repair…" }));
  expect(mock.maintain).not.toHaveBeenCalled();
  const repairDialog = screen.getByRole("dialog");
  await userEvent.click(
    within(repairDialog).getByRole("button", { name: "Restart and repair" })
  );
  await waitFor(() =>
    expect(mock.maintain).toHaveBeenCalledWith({
      action: "reinstall",
      dataPolicy: "preserve",
    })
  );
  await waitFor(() =>
    expect(
      screen
        .getByRole("button", { name: "Reset environment…" })
        .hasAttribute("disabled")
    ).toBe(false)
  );

  // 2. Reset environment
  mock.maintain.mockClear();
  await userEvent.click(screen.getByRole("button", { name: "Reset environment…" }));
  expect(mock.maintain).not.toHaveBeenCalled();
  const resetDialog = screen.getByRole("dialog");
  await userEvent.click(
    within(resetDialog).getByRole("button", { name: "Reset environment" })
  );
  await waitFor(() =>
    expect(mock.maintain).toHaveBeenCalledWith({
      action: "reinstall",
      dataPolicy: "reset",
    })
  );
  await waitFor(() =>
    expect(
      screen.getByRole("button", { name: "Uninstall…" }).hasAttribute("disabled")
    ).toBe(false)
  );

  // 3. Uninstall
  mock.maintain.mockClear();
  await userEvent.click(screen.getByRole("button", { name: "Uninstall…" }));
  expect(mock.maintain).not.toHaveBeenCalled();
  const uninstallDialog = screen.getByRole("dialog");
  await userEvent.click(
    within(uninstallDialog).getByRole("button", { name: "Uninstall components" })
  );
  await waitFor(() =>
    expect(mock.maintain).toHaveBeenCalledWith({
      action: "uninstall",
      dataPolicy: "reset",
    })
  );
});

it("shows installed and target version in Diagnostic details", async () => {
  mock.host = {
    installation: "installed",
    installedReleaseId: "operator-release",
    updateAvailable: false,
  };
  await show();
  await userEvent.click(
    screen.getByRole("button", { name: "Sandbox storage & maintenance" })
  );
  await userEvent.click(screen.getByText("Diagnostic details"));
  expect(screen.getByText("operator-release")).toBeTruthy();
  expect(screen.getByText("Version unknown")).toBeTruthy();
});

it("refreshes a ready workload projection only when native binding or operation facts change", async () => {
  mock.state = { ...mock.state, status: "ready", desiredEnabled: true };
  const view = render(<Harness />);
  await act(async () => {});
  const reads = mock.workloadRefresh.mock.calls.length;
  mock.state = { ...mock.state, revision: 4, bindingRevision: 4 };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads);
  mock.state = {
    ...mock.state,
    bindingRegistrationId: undefined,
    bindingWorkspaceId: undefined,
    desiredEnabled: false,
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 1);
  mock.state = {
    ...mock.state,
    desiredEnabled: true,
    bindingWorkspaceId: "workspace",
    bindingRegistrationId: "new-registration",
    operation: { requestId: "enable-new", kind: "configure", outcome: "pending" },
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 2);
  mock.state = {
    ...mock.state,
    operation: { ...mock.state.operation!, outcome: "succeeded" },
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 3);
  mock.state = {
    ...mock.state,
    facets: { ...mock.state.facets, workActivity: "active" },
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 4);
  act(() => window.dispatchEvent(new Event("focus")));
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 5);
});

it("stops spinning a starting workload row when background observation is paused", async () => {
  mock.state = { ...mock.state, status: "ready", desiredEnabled: true };
  mock.rows = [
    {
      id: "w_service",
      environment_id: "env",
      kind: "service",
      name: "Service",
      desired_state: "ready",
      observed_state: "pending",
      phase: "starting",
      generation: 1,
      revision: 1,
    },
  ];
  const view = render(<Harness />);
  await act(async () => {});
  const activeStatus = screen.getByText("Preparing").closest("output.compute-status")!;
  expect(activeStatus.getAttribute("data-pending")).toBe("true");

  mock.observationPaused = true;
  view.rerender(<Harness />);
  await act(async () => {});
  expect(screen.getByRole("button", { name: "Continue checking" })).toBeTruthy();
  const pausedStatus = screen.getByText("Preparing").closest("output.compute-status")!;
  expect(pausedStatus.getAttribute("data-pending")).toBe("false");
});

/** Agent VMM after the person uninstalled it, keeping its data; Main kept the node's saved setup. */
function uninstall() {
  mock.host = {
    installation: "not_installed",
    selectedReleaseId: "release",
    updateAvailable: false,
    operation: {
      requestId: failedRequest,
      action: "uninstall",
      dataPolicy: "preserve",
      phase: "completed",
      outcome: "succeeded",
    },
  };
  mock.state = {
    ...mock.state,
    problem: "host_uninstalled",
    primaryAction: "update_host",
    currentRequest: { requestId: "claim-1", kind: "configure" },
    observed: { ...mock.state.observed, host: "absent", connector: "absent" },
    facets: { ...mock.state.facets, installationHealth: "absent" },
  };
}

it("shows an uninstalled Agent VMM as a neutral row whose one action reinstalls it", async () => {
  uninstall();
  const card = await show();
  const reason = card.getByText("Agent VMM is uninstalled");
  expect(reason.getAttribute("data-attention")).toBeNull();
  const reinstall = card.getByRole("button", { name: "Keep data and reinstall" });
  expect(card.queryByRole("button", { name: "Check status" })).toBeNull();
  await userEvent.click(reinstall);
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "reinstall",
    dataPolicy: "preserve",
  });
});

it("shows one disk line while Agent VMM is uninstalled", async () => {
  uninstall();
  mock.disposal = { requestId: failedRequest, outcome: "unknown" };
  await show();
  await userEvent.click(
    screen.getByRole("button", { name: "Sandbox storage & maintenance" })
  );
  expect(
    screen.getAllByText("Reinstall Agent VMM to see data disk usage.")
  ).toHaveLength(1);
  expect(screen.getByRole("button", { name: "Keep data and reinstall" })).toBeTruthy();
});

it("says once that disk usage is unavailable when an installed Agent VMM gives no sample", async () => {
  await show();
  await userEvent.click(
    screen.getByRole("button", { name: "Sandbox storage & maintenance" })
  );
  expect(screen.getAllByText("Data disk usage is unavailable.")).toHaveLength(1);
});

it("reads the local maintenance record again when Check status is selected", async () => {
  mock.host = { ...installed, recordUnreadable: true };
  const card = await show();
  expect(card.getByText(/Cannot read the compute record/)).toBeTruthy();
  const reads = mock.read.mock.calls.length;
  mock.host = installed;
  await userEvent.click(card.getByRole("button", { name: "Check status" }));
  expect(mock.refresh).toHaveBeenCalled();
  expect(mock.read.mock.calls.length).toBeGreaterThan(reads);
  expect(card.queryByText(/Cannot read the compute record/)).toBeNull();
});

it("shows a failed request as preparing while Continue maintenance is submitted", async () => {
  const failed = {
    requestId: failedRequest,
    action: "reinstall" as const,
    dataPolicy: "preserve" as const,
    phase: "failed" as const,
    failedPhase: "installing" as const,
    outcome: "failed" as const,
  };
  mock.host = { ...installed, operation: failed };
  let finish!: (state: HostMaintenanceState) => void;
  mock.resume.mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      })
  );
  const card = await show();
  expect(card.getByText(/Comma could not install the components/)).toBeTruthy();
  await userEvent.click(card.getByRole("button", { name: "Continue maintenance" }));
  expect(mock.resume).toHaveBeenCalledWith({ requestId: failedRequest });
  expect(card.getByText("Preparing maintenance")).toBeTruthy();
  expect(card.queryByText(/Comma could not install the components/)).toBeNull();
  expect(card.queryByRole("button", { name: "Continue maintenance" })).toBeNull();
  await act(async () => finish({ ...installed, operation: failed }));
});
